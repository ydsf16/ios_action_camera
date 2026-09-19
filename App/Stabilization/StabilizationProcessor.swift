// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

final class ProcessingControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var paused = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func pause(_ value: Bool) { lock.lock(); paused = value; lock.unlock() }
    func checkpoint() throws {
        while true {
            lock.lock(); let stop = cancelled, wait = paused; lock.unlock()
            if stop { throw CancellationError() }
            if !wait { return }
            Thread.sleep(forTimeInterval: 0.03)
        }
    }
}

/// Offline worker. Native pixel orientation and original movie PTS are preserved.
enum StabilizationProcessor {
    static let filename = "stabilized.mov"
    enum ParameterConflict: LocalizedError {
        case cropLimit
        var errorDescription: String? { "这些设置无法同时保留完整画面。可增大裁切、允许黑边，或使用推荐设置。" }
    }
    private static func makeEngine(_ config: StabilizationInput) throws -> OpaquePointer {
        let json = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        var error = [CChar](repeating: 0, count: 2048)
        guard let engine = json.withCString({ roamshot_engine_create($0, &error, error.count) }) else {
            let reason = String(cString: error)
            if reason.hasPrefix("裁切上限不足：") { throw ParameterConflict.cropLimit }
            throw InputError("稳定引擎初始化失败：\(reason)")
        }
        return engine
    }
    private static func report(_ engine: OpaquePointer) throws -> StabilizationReport {
        var value = RoamShotStabilizationReport()
        guard roamshot_engine_report(engine, &value) == 0 else { throw InputError("无法读取稳定处理结果。") }
        return StabilizationReport(requestedSmoothingSeconds: value.requested_smoothing_seconds,
            effectiveSmoothingSeconds: value.effective_smoothing_seconds, minimumCrop: value.minimum_crop, maximumCrop: value.maximum_crop,
            requestedHorizonPercent: value.requested_horizon_percent, effectiveHorizonPercent: value.effective_horizon_percent,
            locallyAdjusted: value.locally_adjusted > 0.5)
    }
    private static func validateTransform(_ transform: CGAffineTransform, config: StabilizationInput) throws {
        guard config.options.horizonLock else { return }
        let expected = CGAffineTransform(rotationAngle: Double(config.display_rotation_degrees) * .pi / 180)
        guard zip([transform.a, transform.b, transform.c, transform.d], [expected.a, expected.b, expected.c, expected.d])
            .allSatisfy({ abs($0.0-$0.1) < 0.0001 }) else {
            throw InputError("视频显示方向与录制信息不一致，无法可靠锁定水平。")
        }
    }
    /// Metadata/pose-only feasibility check. Does not decode pixels, encode a trial
    /// movie, save options, or touch an existing result/receipt.
    static func preflight(directory: URL, options: StabilizationOptions, control: ProcessingControl) async throws -> StabilizationReport {
        try control.checkpoint()
        let config = try StabilizationInput.load(directory: directory, options: options)
        try control.checkpoint()
        let engine = try makeEngine(config)
        defer { roamshot_engine_destroy(engine) }
        try control.checkpoint()
        let asset = AVURLAsset(url: directory.appendingPathComponent("video.mov"))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw InputError("找不到视频轨道。") }
        try validateTransform(try await track.load(.preferredTransform), config: config)
        try control.checkpoint()
        return try report(engine)
    }
    static func process(directory: URL, options: StabilizationOptions, control: ProcessingControl, progress: @escaping (Double) -> Void) async throws -> URL {
        let processingStarted = Date()
        var timings: [String: Double] = [:]
        var stageStarted = CFAbsoluteTimeGetCurrent()
        func measured(_ name: String) { let now = CFAbsoluteTimeGetCurrent(); timings[name, default: 0] += now-stageStarted; stageStarted = now }
        var legacy = false
        var referenceSampling = false
        #if DEBUG
        legacy = ProcessInfo.processInfo.arguments.contains("--legacy-bgra")
        referenceSampling = ProcessInfo.processInfo.arguments.contains("--reference-lanczos")
        #endif
        func mark(_ stage: String) {
            let state = ["stage": stage, "updated_at": ISO8601DateFormatter().string(from: Date())]
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("processing-status.json"), options: .atomic)
            }
        }
        mark("reading-input")
        let config = try StabilizationInput.load(directory: directory, options: options)
        var errorBuffer = [CChar](repeating: 0, count: 2048)
        measured("input_parse_seconds")
        mark("waiting-for-capture")
        try control.checkpoint()
        mark("initializing-core")
        let engine = try makeEngine(config)
        defer { roamshot_engine_destroy(engine) }
        let stabilizationReport = try report(engine)
        measured("pose_smoothing_crop_seconds")
        let renderer = try legacy ? nil : MetalStabilizer(referenceSampling: referenceSampling)
        let pixelFormat = legacy ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        measured("metal_setup_seconds")
        mark("loading-video-track")
        let original = directory.appendingPathComponent("video.mov")
        let destination = directory.appendingPathComponent(filename)
        let temporary = directory.appendingPathComponent("stabilized-\(UUID().uuidString).partial.mov")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let asset = AVURLAsset(url: original)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw InputError("找不到视频轨道。") }
        let displayTransform = try await videoTrack.load(.preferredTransform)
        try validateTransform(displayTransform, config: config)
        let reader = try AVAssetReader(asset: asset)
        let videoReader = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        videoReader.alwaysCopiesSampleData = false
        guard reader.canAdd(videoReader) else { throw InputError("无法解码视频。") }
        reader.add(videoReader)
        mark("loading-audio-track")
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        var audioReader: AVAssetReaderTrackOutput?
        if let track = audioTrack {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { throw InputError("无法读取声音。") }
            reader.add(output); audioReader = output
        }
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mov)
        writer.movieTimeScale = 1_000_000
        let videoWriter = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: config.output_width, AVVideoHeightKey: config.output_height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: CaptureFormat.videoBitRate(width: config.output_width, height: config.output_height, fps: Int(config.fps)),
                AVVideoExpectedSourceFrameRateKey: Int(config.fps), AVVideoAllowFrameReorderingKey: false]])
        videoWriter.mediaTimeScale = 1_000_000
        videoWriter.transform = displayTransform
        guard writer.canAdd(videoWriter) else { throw InputError("无法创建视频编码器。") }
        writer.add(videoWriter)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoWriter, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: config.output_width, kCVPixelBufferHeightKey as String: config.output_height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        var audioWriter: AVAssetWriterInput?
        if let track = audioTrack {
            guard let format = try await track.load(.formatDescriptions).first else { throw InputError("原片声音格式不可用。") }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            guard writer.canAdd(input) else { throw InputError("无法保留原片声音。") }
            writer.add(input); audioWriter = input
        }
        mark("starting-codecs")
        guard writer.startWriting(), reader.startReading() else { throw writer.error ?? reader.error ?? InputError("无法开始处理素材。") }
        writer.startSession(atSourceTime: .zero)
        var completed = false
        var audioTask: Task<Void, Error>?
        defer {
            if !completed {
                control.cancel(); reader.cancelReading(); writer.cancelWriting(); audioTask?.cancel()
            }
        }
        guard let pool = adaptor.pixelBufferPool else { throw InputError("无法分配视频缓存。") }
        func waitForInput(_ input: AVAssetWriterInput) throws {
            var waited = 0
            while !input.isReadyForMoreMediaData {
                try control.checkpoint()
                guard writer.status == .writing else { throw writer.error ?? InputError("编码停止。") }
                guard waited < 60_000 else { throw InputError("编码器等待超时，请重试。") }
                Thread.sleep(forTimeInterval: 0.0005)
                waited += 1
            }
        }
        // Each writer input must progress independently. Compressed audio samples
        // may contain many packets; a timestamp-based sequential loop can deadlock
        // when the video input applies backpressure while waiting for more audio/EOF.
        if let audioReader, let audioWriter {
            audioTask = Task.detached(priority: .utility) {
                defer { audioWriter.markAsFinished() }
                while let sample = audioReader.copyNextSampleBuffer() {
                    try control.checkpoint()
                    try waitForInput(audioWriter)
                    guard audioWriter.append(sample) else { throw writer.error ?? InputError("声音写入失败。") }
                }
                guard reader.status != .failed else { throw reader.error ?? InputError("声音读取失败。") }
            }
        }
        measured("codec_setup_seconds")
        struct Pending {
            let frame: MetalStabilizer.Frame
            let pts: CMTime
        }
        var pending: [Pending] = []
        var rendered = 0
        func drain() throws {
            let next = pending.removeFirst()
            let start = CFAbsoluteTimeGetCurrent()
            timings["gpu_command_intervals_seconds", default: 0] += try next.frame.finish()
            timings["gpu_wait_seconds", default: 0] += CFAbsoluteTimeGetCurrent()-start
            let encodeStart = CFAbsoluteTimeGetCurrent()
            try waitForInput(videoWriter)
            let appendStart = CFAbsoluteTimeGetCurrent()
            timings["encoder_readiness_wait_seconds", default: 0] += appendStart - encodeStart
            guard adaptor.append(next.frame.output, withPresentationTime: next.pts) else { throw writer.error ?? InputError("输出帧写入失败。") }
            timings["encoder_append_seconds", default: 0] += CFAbsoluteTimeGetCurrent() - appendStart
            timings["encode_wait_append_seconds", default: 0] += CFAbsoluteTimeGetCurrent()-encodeStart
            rendered += 1
            if rendered % 15 == 0 { progress(Double(rendered)/Double(config.frames.count)*0.95) }
        }
        var count = 0
        var endTime = CMTime.zero
        do {
            mark("reading-first-video")
            while true {
                try control.checkpoint()
                // Bounded to three frames: overlap decode / Metal / encode without growing memory.
                if pending.count >= 3 { try drain() }
                let decodeStart = CFAbsoluteTimeGetCurrent()
                guard let sample = videoReader.copyNextSampleBuffer() else { break }
                timings["decode_seconds", default: 0] += CFAbsoluteTimeGetCurrent()-decodeStart
                if count % 60 == 0 { mark("processing-frame-\(count)") }
                try autoreleasepool {
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    let timestamp = Int64((pts.seconds * 1e6).rounded())
                    guard count < config.frames.count, abs(timestamp-config.frames[count].timestamp_us) <= 5 else {
                        throw InputError("视频文件时间戳与录制数据不一致，已停止处理。")
                    }
                    guard let source = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetWidth(source) == config.width,
                          CVPixelBufferGetHeight(source) == config.height else { throw InputError("解码尺寸与内参不匹配。") }
                    let allocationStart = CFAbsoluteTimeGetCurrent()
                    var result: CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &result) == kCVReturnSuccess, let result else {
                        throw InputError("内存不足，无法分配输出帧。")
                    }
                    timings["pool_seconds", default: 0] += CFAbsoluteTimeGetCurrent()-allocationStart
                    if let renderer {
                        let transformStart = CFAbsoluteTimeGetCurrent()
                        var rows = [Float](repeating: 0, count: 12)
                        guard roamshot_engine_transform(engine, timestamp, &rows, rows.count) == 0 else { throw InputError("素材不支持当前 Metal 投影模型。") }
                        timings["frame_transform_seconds", default: 0] += CFAbsoluteTimeGetCurrent()-transformStart
                        let submitStart = CFAbsoluteTimeGetCurrent()
                        let frame = try renderer.submit(source: source, output: result, rows: rows)
                        pending.append(Pending(frame: frame, pts: pts))
                        timings["gpu_submit_seconds", default: 0] += CFAbsoluteTimeGetCurrent()-submitStart
                    } else {
                        // Retained solely for controlled performance/correctness comparisons.
                        let start = CFAbsoluteTimeGetCurrent()
                        CVPixelBufferLockBaseAddress(source, .readOnly); CVPixelBufferLockBaseAddress(result, [])
                        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly); CVPixelBufferUnlockBaseAddress(result, []) }
                        guard let src = CVPixelBufferGetBaseAddress(source), let dst = CVPixelBufferGetBaseAddress(result) else { throw InputError("视频缓存不可用。") }
                        let code = roamshot_engine_process(engine, timestamp,
                            src.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetDataSize(source), CVPixelBufferGetBytesPerRow(source),
                            dst.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetDataSize(result), CVPixelBufferGetBytesPerRow(result),
                            &errorBuffer, errorBuffer.count)
                        guard code == 0 else { throw InputError("稳定处理失败：\(String(cString: errorBuffer))") }
                        timings["legacy_gpu_roundtrip_seconds", default: 0] += CFAbsoluteTimeGetCurrent()-start
                        let encodeStart = CFAbsoluteTimeGetCurrent()
                        try waitForInput(videoWriter)
                        guard adaptor.append(result, withPresentationTime: pts) else { throw writer.error ?? InputError("输出帧写入失败。") }
                        timings["encode_wait_append_seconds", default: 0] += CFAbsoluteTimeGetCurrent()-encodeStart
                        rendered += 1
                        if rendered % 15 == 0 { progress(Double(rendered)/Double(config.frames.count)*0.95) }
                    }
                    let duration = CMSampleBufferGetDuration(sample)
                    endTime = CMTimeAdd(pts, duration.isNumeric && duration.seconds > 0 ? duration : CMTime(value: 1, timescale: CMTimeScale(config.fps)))
                    count += 1
                }
            }
            while !pending.isEmpty { try control.checkpoint(); try drain() }
            stageStarted = CFAbsoluteTimeGetCurrent()
            guard reader.status != .failed, count == config.frames.count else { throw reader.error ?? InputError("解码帧数不完整。") }
            videoWriter.markAsFinished()
            mark("waiting-for-audio")
            try await audioTask?.value
            writer.endSession(atSourceTime: endTime)
            mark("finishing-container")
            await writer.finishWriting()
            try control.checkpoint()
            guard writer.status == .completed else { throw writer.error ?? InputError("稳定视频封装失败。") }
            measured("finish_audio_container_seconds")
            let receipt: [String:Any] = ["engine":"Gyroflow 1.6.3", "backend":legacy ? "Metal (wgpu BGRA benchmark)" : "Metal NV12 IOSurface", "timings":timings, "max_inflight_frames":legacy ? 1 : 3, "app_cpu_pixel_copies_per_frame":legacy ? 2 : 0, "interpolation":"Lanczos4", "processing_seconds":Date().timeIntervalSince(processingStarted), "options": try JSONSerialization.jsonObject(with: JSONEncoder().encode(options)), "input_frames":count,"output_width":config.output_width,
                "sampling_kernel":renderer?.kernelName ?? "wgpu", "output_codec":AVVideoCodecType.h264.rawValue,
                "output_height":config.output_height,"requested_fps":config.fps,"rolling_shutter":false,"horizon_lock":(stabilizationReport.effectiveHorizonPercent ?? 0) > 0,
                "horizon_source":(stabilizationReport.effectiveHorizonPercent ?? 0) > 0 ? "CoreMotion.gravity" : "off", "gravity_samples":config.gravity.count,
                "camera_position":config.camera_facing_front ? "front" : "back",
                "gravity_orientation":config.camera_facing_front
                    ? "front unmirrored image axes = [deviceY, -deviceX, deviceZ]; horizon roll = +displayRotationDegrees"
                    : "rear image axes = [-deviceY, -deviceX, -deviceZ]; horizon roll = -displayRotationDegrees",
                "stabilization": try JSONSerialization.jsonObject(with: JSONEncoder().encode(stabilizationReport)),
                "lens_model":"recorded per-frame K; uncalibrated zero residual distortion", "created_at":ISO8601DateFormatter().string(from:Date())]
            let receiptData = try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys])
            let receiptURL = directory.appendingPathComponent("stabilization.json")
            // Invalidate old diagnostics before publishing a new movie. If publication
            // is interrupted, an absent report is safer than a mismatched old report.
            if FileManager.default.fileExists(atPath: receiptURL.path) {
                try FileManager.default.removeItem(at: receiptURL)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination,withItemAt:temporary)
            } else { try FileManager.default.moveItem(at:temporary,to:destination) }
            do { try receiptData.write(to: receiptURL, options: .atomic) }
            catch {
                // Never attach the previous export's diagnostics to the new movie.
                try? FileManager.default.removeItem(at: receiptURL)
                throw InputError("视频已生成，但处理结果信息未能保存：\(error.localizedDescription)")
            }
            mark("completed")
            completed = true; progress(1)
            return destination
        } catch {
            // Deleting a clip waits for process() to return, including the independent audio worker.
            control.cancel()
            audioTask?.cancel()
            _ = await audioTask?.result
            reader.cancelReading()
            writer.cancelWriting()
            pending.removeAll() // Frame lifetime waits for submitted Metal commands.
            throw error
        }
    }
}
