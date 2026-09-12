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
    static func process(directory: URL, options: StabilizationOptions, control: ProcessingControl, progress: @escaping (Double) -> Void) async throws -> URL {
        func mark(_ stage: String) {
            let state = ["stage": stage, "updated_at": ISO8601DateFormatter().string(from: Date())]
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("processing-status.json"), options: .atomic)
            }
        }
        mark("reading-input")
        let config = try StabilizationInput.load(directory: directory, options: options)
        let json = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        var errorBuffer = [CChar](repeating: 0, count: 2048)
        mark("waiting-for-capture")
        try control.checkpoint()
        mark("initializing-core")
        guard let engine = json.withCString({ mc_engine_create($0, &errorBuffer, errorBuffer.count) }) else {
            throw InputError("稳定引擎初始化失败：\(String(cString: errorBuffer))")
        }
        mark("loading-video-track")
        defer { mc_engine_destroy(engine) }
        let original = directory.appendingPathComponent("video.mov")
        let destination = directory.appendingPathComponent(filename)
        let temporary = directory.appendingPathComponent("stabilized-\(UUID().uuidString).partial.mov")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let asset = AVURLAsset(url: original)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw InputError("找不到视频轨道。") }
        let reader = try AVAssetReader(asset: asset)
        let videoReader = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
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
        let videoWriter = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: config.output_width, AVVideoHeightKey: config.output_height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 16_000_000, AVVideoAllowFrameReorderingKey: false]])
        videoWriter.mediaTimeScale = 1_000_000
        videoWriter.transform = try await videoTrack.load(.preferredTransform)
        guard writer.canAdd(videoWriter) else { throw InputError("无法创建视频编码器。") }
        writer.add(videoWriter)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoWriter, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
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
                guard waited < 10_000 else { throw InputError("编码器等待超时，请重试。") }
                Thread.sleep(forTimeInterval: 0.003)
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
        var count = 0
        var endTime = CMTime.zero
        mark("reading-first-video")
        while let sample = videoReader.copyNextSampleBuffer() {
            if count % 15 == 0 { mark("processing-frame-\(count)") }
            try control.checkpoint()
            try autoreleasepool {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let timestamp = Int64((pts.seconds * 1e6).rounded())
                guard count < config.frames.count, abs(timestamp-config.frames[count].timestamp_us) <= 5 else {
                    throw InputError("视频文件时间戳与录制数据不一致，已停止处理。")
                }
                guard let source = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetWidth(source) == config.width,
                      CVPixelBufferGetHeight(source) == config.height else { throw InputError("解码尺寸与内参不匹配。") }
                var result: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &result) == kCVReturnSuccess, let result else {
                    throw InputError("内存不足，无法分配输出帧。")
                }
                CVPixelBufferLockBaseAddress(source, [])
                CVPixelBufferLockBaseAddress(result, [])
                defer { CVPixelBufferUnlockBaseAddress(source, []); CVPixelBufferUnlockBaseAddress(result, []) }
                guard let src = CVPixelBufferGetBaseAddress(source), let dst = CVPixelBufferGetBaseAddress(result) else { throw InputError("视频缓存不可用。") }
                let code = mc_engine_process(engine, timestamp,
                    src.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetDataSize(source), CVPixelBufferGetBytesPerRow(source),
                    dst.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetDataSize(result), CVPixelBufferGetBytesPerRow(result),
                    &errorBuffer, errorBuffer.count)
                guard code == 0 else { throw InputError("稳定处理失败：\(String(cString: errorBuffer))") }
                try waitForInput(videoWriter)
                guard adaptor.append(result, withPresentationTime: pts) else { throw writer.error ?? InputError("输出帧写入失败。") }
                let duration = CMSampleBufferGetDuration(sample)
                endTime = CMTimeAdd(pts, duration.isNumeric && duration.seconds > 0 ? duration : CMTime(value: 1,timescale: 30))
                count += 1
                progress(Double(count) / Double(config.frames.count) * 0.95)
            }
        }
        guard reader.status != .failed, count == config.frames.count else { throw reader.error ?? InputError("解码帧数不完整。") }
        videoWriter.markAsFinished()
        mark("waiting-for-audio")
        try await audioTask?.value
        writer.endSession(atSourceTime: endTime)
        mark("finishing-container")
        await writer.finishWriting()
        try control.checkpoint()
        guard writer.status == .completed else { throw writer.error ?? InputError("稳定视频封装失败。") }
        let receipt: [String:Any] = ["engine":"Gyroflow 1.6.3", "backend":"CPU", "options": try JSONSerialization.jsonObject(with: JSONEncoder().encode(options)), "input_frames":count,"output_width":config.output_width,
            "output_height":config.output_height,"rolling_shutter":false,"horizon_lock":false,
            "lens_model":"recorded per-frame K; uncalibrated zero residual distortion", "created_at":ISO8601DateFormatter().string(from:Date())]
        try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys])
            .write(to:directory.appendingPathComponent("stabilization.json"),options:.atomic)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination,withItemAt:temporary)
        } else { try FileManager.default.moveItem(at:temporary,to:destination) }
        mark("completed")
        completed = true; progress(1)
        return destination
    }
}
