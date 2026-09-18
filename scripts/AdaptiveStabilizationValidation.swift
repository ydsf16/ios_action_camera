import AVFoundation
import CryptoKit
import Foundation

/// Synthetic motion on a copied recording: a short crop conflict must be resolved
/// locally before encoding while preflight leaves the previous result usable.
enum AdaptiveStabilizationValidation {
    static func run(fixture: URL) async throws {
        func check(_ condition: Bool) throws { if !condition { throw InputError("Adaptive export validation failed") } }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("roamshot-adaptation-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let files = ["video.mov", "frames.csv", "gyro.csv", "manifest.json"]
        var originals: [String: SHA256.Digest] = [:]
        for name in files {
            let source = fixture.appendingPathComponent(name)
            originals[name] = SHA256.hash(data: try Data(contentsOf: source, options: .mappedIfSafe))
            try fm.copyItem(at: source, to: root.appendingPathComponent(name))
        }
        let manifest = try RecordingManifest.read(from: root.appendingPathComponent("manifest.json"))
        let gyroRows = try String(contentsOf: root.appendingPathComponent("gyro.csv"), encoding: .utf8).split(whereSeparator: \.isNewline)
        let timeColumn = gyroRows[0].split(separator: ",").firstIndex(of: "host_sec")!
        let timestamps = try gyroRows.dropFirst().map { row -> Double in
            guard let time = Double(row.split(separator: ",")[timeColumn]) else { throw InputError("Invalid fixture timestamp") }
            return time
        }
        let angle = (Double(manifest.displayRotationDegrees) + 45) * Double.pi / 180
        let gravityRows = timestamps.map { "\($0),\(-cos(angle)),\(-sin(angle)),0" }
        try (["host_sec,gx_g,gy_g,gz_g"] + gravityRows).joined(separator: "\n")
            .write(to: root.appendingPathComponent("gravity.csv"), atomically: true, encoding: .utf8)
        try (["host_sec,gx_rad_s,gy_rad_s,gz_rad_s"] + timestamps.map { "\($0),0,0,0" }).joined(separator: "\n")
            .write(to: root.appendingPathComponent("gyro.csv"), atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("stabilized.mov"), receiptURL = root.appendingPathComponent("stabilization.json")
        let previous = Data("previous result stays available".utf8)
        try previous.write(to: output); try previous.write(to: receiptURL)
        var manual = StabilizationOptions()
        manual.automaticAdjustment = false; manual.smoothingSeconds = 0
        manual.horizonLock = true; manual.maxCrop = 1.05; manual.exportResolution = .fullHD
        let planned = try await StabilizationProcessor.preflight(directory: root, options: manual, control: ProcessingControl())
        try check(planned.localAdjustmentApplied)
        try check(!planned.horizonReduced)
        try check(!fm.fileExists(atPath: root.appendingPathComponent("stabilization-options.json").path))
        try check(try Data(contentsOf: output) == previous)
        try check(try Data(contentsOf: receiptURL) == previous)
        _ = try await StabilizationProcessor.process(directory: root, options: manual, control: ProcessingControl()) { _ in }
        let receipt = StabilizationReport.load(directory: root)!
        try check(receipt.stabilization == planned)
        let asset = AVURLAsset(url: output)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let size = try await track.load(.naturalSize)
        try check(Int(size.width) == min(manifest.width, 1920))
        let reader = try AVAssetReader(asset: asset)
        let samples = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        reader.add(samples); try check(reader.startReading())
        let input = try StabilizationInput.load(directory: root, options: manual)
        var count = 0
        while let frame = samples.copyNextSampleBuffer() {
            let us = CMSampleBufferGetPresentationTimeStamp(frame).seconds * 1e6
            try check(count < input.frames.count && abs(us - Double(input.frames[count].timestamp_us)) <= 1.01)
            count += 1
        }
        try check(reader.status == .completed && count == manifest.videoFrames)
        let sourceAudio = try await AVURLAsset(url: root.appendingPathComponent("video.mov")).loadTracks(withMediaType: .audio)
        let outputAudio = try await asset.loadTracks(withMediaType: .audio)
        try check(outputAudio.count == sourceAudio.count)
        for name in files {
            try check(SHA256.hash(data: try Data(contentsOf: fixture.appendingPathComponent(name), options: .mappedIfSafe)) == originals[name])
        }
        print("PASS: local crop recovery matched preflight; previous movie/receipt survived preflight; \(count) decoded frames, PTS, audio and source hashes verified")
        print("Recovery: \(planned.summary); \(planned.details)")
    }
}
