// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CryptoKit
import Foundation

/// Run through the real Metal exporter using copies of a synthetic recording.
enum OrientationValidation {
    static func run(fixture: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("roamshot-orientation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = fixture.appendingPathComponent("video.mov")
        let originalHash = SHA256.hash(data: try Data(contentsOf: original))
        let asset = AVURLAsset(url: original)
        let duration = try await asset.load(.duration)
        let sourceVideo = try await asset.loadTracks(withMediaType: .video)[0]
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
        for rawAngle in [90.0, 0.0, 180.0, -90.0] {
            guard let angle = RecordingRotation.quarterTurn(from: rawAngle) else { throw InputError("Invalid capture angle") }
            let directory = root.appendingPathComponent("rotation-\(angle)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in ["frames.csv", "gyro.csv"] {
                try FileManager.default.copyItem(at: fixture.appendingPathComponent(name), to: directory.appendingPathComponent(name))
            }
            var manifest = try RecordingManifest.read(from: fixture.appendingPathComponent("manifest.json"))
            manifest.displayRotationDegrees = angle
            try manifest.write(to: directory.appendingPathComponent("manifest.json"))
            let composition = AVMutableComposition()
            let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try video.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceVideo, at: .zero)
            let transform = CGAffineTransform(rotationAngle: Double(angle)*Double.pi/180)
            video.preferredTransform = transform
            if let sourceAudio {
                let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                try audio.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceAudio, at: .zero)
            }
            guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw InputError("Cannot create orientation fixture") }
            exporter.outputURL = directory.appendingPathComponent("video.mov"); exporter.outputFileType = .mov
            await exporter.export()
            guard exporter.status == .completed else { throw exporter.error ?? InputError("Fixture export failed") }
            let config = try StabilizationInput.load(directory: directory)
            let output = try await StabilizationProcessor.process(directory: directory, options: .init(), control: ProcessingControl()) { _ in }
            let movie = AVURLAsset(url: output)
            let track = try await movie.loadTracks(withMediaType: .video)[0]
            let actual = try await track.load(.preferredTransform)
            for (a,b) in zip([actual.a,actual.b,actual.c,actual.d], [transform.a,transform.b,transform.c,transform.d]) {
                guard abs(a-b) < 0.0001 else { throw InputError("Output lost capture rotation \(angle)") }
            }
            let generator = AVAssetImageGenerator(asset: movie)
            generator.appliesPreferredTrackTransform = true
            let image = try await generator.image(at: .zero).image
            let portrait = angle == 90 || angle == 270
            guard image.width == (portrait ? config.output_height : config.output_width),
                  image.height == (portrait ? config.output_width : config.output_height) else { throw InputError("Displayed dimensions are incorrect") }
            let reader = try AVAssetReader(asset: movie)
            // Validate presented frames; compressed packet timing can include preroll.
            let samples = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            samples.alwaysCopiesSampleData = false
            reader.add(samples)
            guard reader.startReading() else { throw reader.error ?? InputError("Cannot read output") }
            var count = 0
            while let sample = samples.copyNextSampleBuffer() {
                let pts = Int64((CMSampleBufferGetPresentationTimeStamp(sample).seconds*1e6).rounded())
                guard count < config.frames.count, abs(pts-config.frames[count].timestamp_us) <= 5 else {
                    throw InputError("Rotation timestamp check: frame \(count), PTS \(pts), expected \(count < config.frames.count ? config.frames[count].timestamp_us : -1), samples \(CMSampleBufferGetNumSamples(sample))")
                }
                count += 1
            }
            guard reader.status == .completed, count == config.frames.count else { throw InputError("Incomplete output") }
            if sourceAudio != nil {
                guard try await movie.loadTracks(withMediaType: .audio).count == 1 else { throw InputError("Output lost audio") }
            }
            print("PASS: \(angle) degrees, displayed \(image.width)x\(image.height), \(count) frames, preserved PTS/audio track")
        }
        guard SHA256.hash(data: try Data(contentsOf: original)) == originalHash else { throw InputError("Original fixture changed") }
        guard RecordingRotation.quarterTurn(from: .nan) == nil, RecordingRotation.quarterTurn(from: .infinity) == nil else { throw InputError("Accepted invalid rotation") }
    }
}
