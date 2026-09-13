// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CryptoKit
import Foundation

/// Exercise the real export/receipt pipeline with deliberately synthetic motion.
enum StabilizationParameterValidation {
    static func run(fixture: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("motioncam-parameters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["video.mov", "frames.csv", "gyro.csv", "manifest.json"]
        let hashes = try names.map { SHA256.hash(data: try Data(contentsOf: fixture.appendingPathComponent($0))) }
        var darkFractions: [String: Double] = [:]
        for (name, seconds, allow, crop) in [("off", 0.0, true, 1.0), ("strong", 4.0, true, 1.0),
                                            ("extra", 6.0, true, 1.0), ("maximum", 10.0, true, 1.0),
                                            ("limited", 4.0, false, 1.2)] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for file in names { try FileManager.default.copyItem(at: fixture.appendingPathComponent(file), to: directory.appendingPathComponent(file)) }
            let gyroFile = directory.appendingPathComponent("gyro.csv")
            let lines = try String(contentsOf: gyroFile).split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") }
            let header = lines[0].split(separator: ",").map(String.init)
            guard let ti = header.firstIndex(of: "host_sec"), let zi = header.firstIndex(of: "gz_rad_s") else { throw InputError("Unexpected fixture gyro columns") }
            let origin = Double(lines[1].split(separator: ",")[ti])!
            var rows = [lines[0].description]
            for line in lines.dropFirst() {
                var columns = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                columns[zi] = String(sin((Double(columns[ti])!-origin)*10)*2)
                rows.append(columns.joined(separator: ","))
            }
            try rows.joined(separator: "\n").write(to: gyroFile, atomically: true, encoding: .utf8)
            var options = StabilizationOptions()
            options.smoothingSeconds = seconds; options.allowBlackBorders = allow
            options.dynamicCrop = false; options.maxCrop = crop
            let config = try StabilizationInput.load(directory: directory, options: options)
            let output = try await StabilizationProcessor.process(directory: directory, options: options, control: ProcessingControl()) { _ in }
            guard let receipt = StabilizationReport.load(directory: directory), receipt.options == options else { throw InputError("Export report/options mismatch") }
            let report = receipt.stabilization
            guard abs(report.requestedSmoothingSeconds-seconds) < 1e-9,
                  report.cropLimited == !allow,
                  abs(report.maximumCrop-crop) < 1e-9,
                  !allow || abs(report.effectiveSmoothingSeconds-seconds) < 1e-9 else { throw InputError("Incorrect effective smoothing/crop diagnostics") }
            let asset = AVURLAsset(url: output)
            let track = try await asset.loadTracks(withMediaType: .video)[0]
            let reader = try AVAssetReader(asset: asset)
            let frames = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            frames.alwaysCopiesSampleData = false; reader.add(frames)
            guard reader.startReading() else { throw InputError("Cannot decode parameter output") }
            var count = 0, dark = 0, pixels = 0
            while let sample = frames.copyNextSampleBuffer() {
                let pts = Int64((CMSampleBufferGetPresentationTimeStamp(sample).seconds*1e6).rounded())
                guard count < config.frames.count, abs(pts-config.frames[count].timestamp_us) <= 5 else { throw InputError("Output PTS changed") }
                if count % 10 == 0, let buffer = CMSampleBufferGetImageBuffer(sample) {
                    CVPixelBufferLockBaseAddress(buffer, .readOnly)
                    let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
                    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                    for y in Swift.stride(from: 0, to: CVPixelBufferGetHeight(buffer), by: 8) {
                        for x in Swift.stride(from: 0, to: CVPixelBufferGetWidth(buffer), by: 8) {
                            if base[y*stride+x] <= 18 { dark += 1 }; pixels += 1
                        }
                    }
                    CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                }
                count += 1
            }
            guard reader.status == .completed, count == config.frames.count,
                  try await asset.loadTracks(withMediaType: .audio).count == 1 else { throw InputError("Output frame/audio loss") }
            darkFractions[name] = Double(dark)/Double(pixels)
            print("PASS \(name): requested=\(seconds)s, effective=\(report.effectiveSmoothingSeconds)s, crop=\(crop)x, \(count) frames, dark fraction=\(darkFractions[name]!)")
        }
        guard darkFractions["maximum"]! > darkFractions["off"]! + 0.01,
              darkFractions["limited"]! < darkFractions["strong"]! else { throw InputError("Black-border policy did not change rendered pixels") }
        // Exercise replacement too: the displayed report must belong to the new movie.
        let replaceDirectory = root.appendingPathComponent("maximum")
        var replacement = StabilizationOptions()
        replacement.smoothingSeconds = 0; replacement.allowBlackBorders = true
        replacement.dynamicCrop = false; replacement.maxCrop = 1
        _ = try await StabilizationProcessor.process(directory: replaceDirectory, options: replacement, control: ProcessingControl()) { _ in }
        guard let replaced = StabilizationReport.load(directory: replaceDirectory),
              replaced.options == replacement, replaced.stabilization.effectiveSmoothingSeconds == 0 else { throw InputError("Regenerated movie retained stale diagnostics") }
        print("PASS replacement: previous 10s result replaced with off; receipt matches new options")
        for (name, hash) in zip(names, hashes) {
            guard SHA256.hash(data: try Data(contentsOf: fixture.appendingPathComponent(name))) == hash else { throw InputError("Original fixture changed") }
        }
    }
}
