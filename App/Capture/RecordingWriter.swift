import AVFoundation
import UIKit
import simd

enum CaptureFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

extension MediaTime {
    init(_ time: CMTime) { self.init(value: time.value, timescale: time.timescale) }
}

final class RecordingWriter {
    let directory: URL
    private(set) var manifest: RecordingManifest
    private let frames: CSVFile
    private let audioTimes: CSVFile
    private let drops: CSVFile
    private let gyro: CSVFile
    private let accelerometer: CSVFile
    private let gravity: CSVFile
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var captureBufferCopier: CaptureBufferCopier?
    private var timeline = VideoTimeline()
    private var lastAudioPTS: CMTime?
    private var lastVideoEnd: CMTime?
    private var started = false
    private var errorMessage: String?
    private var csvClosed = false

    init(root: URL, device: AVCaptureDevice, connection: AVCaptureConnection, rotationDegrees: Int, exposurePolicy: String, captureFormat: CaptureFormat) throws {
        let date = Date()
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let id = "MC_\(format.string(from: date))_\(UUID().uuidString.prefix(8))"
        directory = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        var sys = utsname()
        uname(&sys)
        let model = withUnsafeBytes(of: &sys.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        manifest = RecordingManifest(id: id, createdAt: date,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
            deviceModel: model, systemVersion: UIDevice.current.systemVersion,
            camera: device.deviceType.rawValue, width: Int(size.width), height: Int(size.height),
            stabilizationActive: connection.activeVideoStabilizationMode.rawValue,
            intrinsicsDeliveryEnabled: connection.isCameraIntrinsicMatrixDeliveryEnabled)
        manifest.displayRotationDegrees = rotationDegrees
        manifest.requestedFPS = captureFormat.fps
        manifest.appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        manifest.captureBufferStrategy = captureFormat.fps >= 60 ? "metal_nv12_owned_pool_8" : "camera_buffers_direct"
        let maximumExposure = device.activeMaxExposureDuration.seconds
        manifest.maximumAutoExposureSeconds = maximumExposure.isFinite ? maximumExposure : nil
        manifest.exposurePolicy = exposurePolicy
        manifest.continuousAutoFocusEnabled = device.focusMode == .continuousAutoFocus
        manifest.systemTimestampSynchronizationEnabled = true
        manifest.hardwareTriggeredSynchronizationEnabled = false
        manifest.warnings = ["OIS state is not guaranteed by stabilizationMode=off.",
                             "Rolling shutter readout and lens distortion are uncalibrated."]
        frames = try CSVFile(url: directory.appendingPathComponent("frames.csv"),
            header: "frame,pts_value,pts_timescale,host_sec,video_sec,width,height,k00,k01,k02,k10,k11,k12,k20,k21,k22,exposure_sec_observed,iso_observed,focus_observed,zoom_observed,stabilization_active")
        audioTimes = try CSVFile(url: directory.appendingPathComponent("audio.csv"),
            header: "buffer,pts_value,pts_timescale,host_sec,video_sec,samples,duration_sec")
        drops = try CSVFile(url: directory.appendingPathComponent("drops.csv"), header: "stream,pts_value,pts_timescale,reason")
        gyro = try CSVFile(url: directory.appendingPathComponent("gyro.csv"), header: "host_sec,gx_rad_s,gy_rad_s,gz_rad_s")
        accelerometer = try CSVFile(url: directory.appendingPathComponent("accelerometer.csv"), header: "host_sec,ax_g,ay_g,az_g")
        gravity = try CSVFile(url: directory.appendingPathComponent("gravity.csv"), header: "host_sec,gx_g,gy_g,gz_g,qx,qy,qz,qw")
        try manifest.write(to: directory.appendingPathComponent("manifest.json"))
    }

    func appendMotion(_ kind: String, row: String) throws {
        switch kind {
        case "gyro": try gyro.append(row); manifest.gyroSamples += 1
        case "accelerometer": try accelerometer.append(row); manifest.accelerometerSamples += 1
        default: try gravity.append(row); manifest.gravitySamples += 1
        }
    }

    private func hostTime(_ pts: CMTime, clock: CMClock?) throws -> Double {
        guard pts.isValid, pts.isNumeric, let clock else {
            throw CaptureFailure.message("无法获取采集时钟，已停止录制以保护时间同步。")
        }
        let host = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
        guard host.isValid, host.isNumeric, host.seconds.isFinite else {
            throw CaptureFailure.message("视频时间戳转换失败。")
        }
        return host.seconds
    }

    private func start(_ sample: CMSampleBuffer) throws {
        guard let pixel = CMSampleBufferGetImageBuffer(sample) else { throw CaptureFailure.message("没有视频图像。") }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        manifest.width = width; manifest.height = height
        if manifest.requestedFPS >= 60 { captureBufferCopier = try CaptureBufferCopier(width: width, height: height) }
        let writer = try AVAssetWriter(outputURL: directory.appendingPathComponent("video.partial.mov"), fileType: .mov)
        writer.movieTimeScale = 1_000_000
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: CaptureFormat.videoBitRate(width: width, height: height, fps: manifest.requestedFPS),
                AVVideoExpectedSourceFrameRateKey: manifest.requestedFPS, AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings,
                                      sourceFormatHint: CMSampleBufferGetFormatDescription(sample))
        video.expectsMediaDataInRealTime = true
        video.mediaTimeScale = 1_000_000
        // Keep native buffers/IMU/intrinsics; lock display orientation at recording start.
        video.transform = CGAffineTransform(rotationAngle: Double(manifest.displayRotationDegrees) * .pi / 180)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000])
        audio.expectsMediaDataInRealTime = true
        guard writer.canApply(outputSettings: settings, forMediaType: .video),
              writer.canAdd(video), writer.canAdd(audio) else { throw CaptureFailure.message("此设备不支持当前录制格式。") }
        writer.add(video); writer.add(audio)
        assetWriter = writer; videoInput = video; audioInput = audio
        guard writer.startWriting() else { throw writer.error ?? CaptureFailure.message("无法启动视频编码。") }
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
        started = true
    }

    func appendVideo(_ sample: CMSampleBuffer, device: AVCaptureDevice,
                     connection: AVCaptureConnection, clock: CMClock?) throws {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let host = try hostTime(pts, clock: clock)
        if !started { try start(sample) }
        guard let input = videoInput, let writer = assetWriter, writer.status == .writing else {
            throw assetWriter?.error ?? CaptureFailure.message("视频编码意外停止。")
        }
        guard input.isReadyForMoreMediaData else {
            if manifest.videoFrames == 0 { throw CaptureFailure.message("编码器尚未就绪，请重试录制。") }
            try drop("video", pts: pts, reason: "encoder_backpressure"); return
        }
        let encoderSample: CMSampleBuffer
        if let captureBufferCopier {
            guard let copy = try captureBufferCopier.copy(sample) else {
                try drop("video", pts: pts, reason: "capture_copy_pool_full"); return
            }
            encoderSample = copy
        } else { encoderSample = sample }
        let relative = try timeline.accept(MediaTime(pts))
        guard input.append(encoderSample) else { throw writer.error ?? CaptureFailure.message("视频帧写入失败。") }
        if manifest.firstVideoPTS == nil {
            manifest.firstVideoPTS = MediaTime(pts)
            manifest.firstVideoHostSeconds = host
            try manifest.write(to: directory.appendingPathComponent("manifest.json"))
        }
        let k = intrinsics(sample)
        if k != nil { manifest.framesWithIntrinsics += 1 }
        let matrix = (k ?? Array(repeating: Double.nan, count: 9)).map { String($0) }.joined(separator: ",")
        try frames.append("\(manifest.videoFrames),\(pts.value),\(pts.timescale),\(host),\(relative),\(manifest.width),\(manifest.height),\(matrix),\(device.exposureDuration.seconds),\(device.iso),\(device.lensPosition),\(device.videoZoomFactor),\(connection.activeVideoStabilizationMode.rawValue)")
        manifest.videoFrames += 1
        let duration = CMSampleBufferGetDuration(sample)
        let validDuration = duration.isNumeric && duration.seconds > 0 ? duration : CMTime(value: 1, timescale: CMTimeScale(manifest.requestedFPS))
        lastVideoEnd = CMTimeAdd(pts, validDuration)
        manifest.durationSeconds = relative + validDuration.seconds
    }

    func appendAudio(_ sample: CMSampleBuffer, clock: CMClock?) throws {
        guard started, let first = manifest.firstVideoPTS, let input = audioInput,
              let writer = assetWriter else { return } // Video establishes the common origin.
        guard writer.status == .writing else { throw writer.error ?? CaptureFailure.message("音频编码意外停止。") }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let host = try hostTime(pts, clock: clock)
        guard pts.seconds >= first.seconds else { return }
        if let lastAudioPTS, CMTimeCompare(pts, lastAudioPTS) <= 0 {
            try drop("audio", pts: pts, reason: "non_monotonic_pts"); return
        }
        guard input.isReadyForMoreMediaData else { try drop("audio", pts: pts, reason: "encoder_backpressure"); return }
        guard input.append(sample) else { throw writer.error ?? CaptureFailure.message("音频写入失败。") }
        lastAudioPTS = pts
        try audioTimes.append("\(manifest.audioBuffers),\(pts.value),\(pts.timescale),\(host),\(pts.seconds - first.seconds),\(CMSampleBufferGetNumSamples(sample)),\(CMSampleBufferGetDuration(sample).seconds)")
        manifest.audioBuffers += 1
    }

    func drop(_ stream: String, pts: CMTime, reason: String) throws {
        if stream == "video" { manifest.droppedVideoFrames += 1 } else { manifest.droppedAudioBuffers += 1 }
        let safeReason = reason.replacingOccurrences(of: ",", with: ";").replacingOccurrences(of: "\n", with: " ")
        try drops.append("\(stream),\(pts.value),\(pts.timescale),\(safeReason)")
    }

    func markError(_ error: Error) { errorMessage = error.localizedDescription }

    func finish(reason: String, queue: DispatchQueue, completion: @escaping (Result<URL, Error>) -> Void) {
        manifest.stopReason = reason
        do {
            try closeCSV()
        } catch { errorMessage = error.localizedDescription }
        guard let writer = assetWriter, started, manifest.videoFrames > 0, writer.status == .writing else {
            assetWriter?.cancelWriting()
            finalize(error: errorMessage ?? assetWriter?.error?.localizedDescription ?? "录制时间过短，没有可保存的视频。", completion: completion)
            return
        }
        if let lastVideoEnd { writer.endSession(atSourceTime: lastVideoEnd) }
        videoInput?.markAsFinished(); audioInput?.markAsFinished()
        writer.finishWriting { [self] in
            queue.async {
                let message = writer.status == .completed ? self.errorMessage : (writer.error?.localizedDescription ?? "视频封装失败。")
                self.finalize(error: message, completion: completion)
            }
        }
    }

    private func finalize(error: String?, completion: (Result<URL, Error>) -> Void) {
        do {
            if assetWriter?.status == .completed {
                try FileManager.default.moveItem(at: directory.appendingPathComponent("video.partial.mov"),
                                                to: directory.appendingPathComponent("video.mov"))
            }
            if manifest.framesWithIntrinsics != manifest.videoFrames { manifest.warnings.append("Some frames have no intrinsic matrix.") }
            if manifest.audioBuffers == 0 { manifest.warnings.append("No audio samples were recorded.") }
            manifest.error = error
            manifest.status = error == nil ? "complete" : "failed"
            try manifest.write(to: directory.appendingPathComponent("manifest.json"))
            if let error { completion(.failure(CaptureFailure.message(error))) }
            else { completion(.success(directory)) }
        } catch { completion(.failure(error)) }
    }

    private func closeCSV() throws {
        guard !csvClosed else { return }
        var failure: Error?
        for csv in [frames, audioTimes, drops, gyro, accelerometer, gravity] {
            do { try csv.close() } catch { failure = error }
        }
        csvClosed = true
        if let failure { throw failure }
    }

    private func intrinsics(_ sample: CMSampleBuffer) -> [Double]? {
        guard let attachment = CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                               attachmentModeOut: nil), CFGetTypeID(attachment) == CFDataGetTypeID() else { return nil }
        let data = attachment as! CFData
        guard CFDataGetLength(data) >= MemoryLayout<simd_float3x3>.size else { return nil }
        var matrix = matrix_identity_float3x3
        withUnsafeMutableBytes(of: &matrix) { buffer in
            buffer.copyBytes(from: UnsafeRawBufferPointer(start: CFDataGetBytePtr(data), count: MemoryLayout<simd_float3x3>.size))
        }
        return (0..<3).flatMap { row in (0..<3).map { col in Double(matrix[col][row]) } }
    }
}
