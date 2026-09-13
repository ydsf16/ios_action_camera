import CoreMedia
import CoreVideo
import Metal
import Foundation

/// At 4K60 the encoder may retain camera-owned NV12 buffers until the camera pool
/// runs dry. A bounded IOSurface pool decouples their lifetimes with a Metal blit.
/// No CPU pixel access, color conversion or timestamp changes occur here.
final class CaptureBufferCopier {
    // Reserve headroom for encoder retention at 4K60. Codec selection separately
    // addresses sustained throughput; extra buffers alone cannot fix that. Bound
    // to about 190 MiB of NV12 image data at 4K (plus platform stride/metadata).
    static let capacity = 16
    private(set) var copiedFrames = 0
    private(set) var poolFullDrops = 0
    private(set) var copySeconds = 0.0
    private(set) var maximumCopySeconds = 0.0
    private let pool: CVPixelBufferPool
    private let queue: MTLCommandQueue
    private let cache: CVMetalTextureCache

    init(width: Int, height: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw InputError("60 fps 录制需要 Metal。")
        }
        self.queue = queue
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw InputError("无法创建录制纹理缓存。")
        }
        self.cache = cache
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
            throw InputError("无法创建录制缓冲池。")
        }
        self.pool = pool
    }

    /// nil means bounded backpressure; the caller records the dropped source PTS.
    func copy(_ sample: CMSampleBuffer) throws -> CMSampleBuffer? {
        let began = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - began
            copySeconds += elapsed
            maximumCopySeconds = max(maximumCopySeconds, elapsed)
        }
        guard let source = CMSampleBufferGetImageBuffer(sample),
              let description = CMSampleBufferGetFormatDescription(sample),
              CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              CVPixelBufferGetPlaneCount(source) == 2 else { throw InputError("录制缓存格式不匹配。") }
        var output: CVPixelBuffer?
        let limit = [kCVPixelBufferPoolAllocationThresholdKey as String: Self.capacity] as CFDictionary
        var status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limit, &output)
        if status == kCVReturnWouldExceedAllocationThreshold {
            // Evict unused texture wrappers before deciding that the encoder
            // still owns the whole pool. Do not increase the allocation limit.
            CVMetalTextureCacheFlush(cache, 0)
            status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limit, &output)
        }
        if status == kCVReturnWouldExceedAllocationThreshold { poolFullDrops += 1; return nil }
        guard status == kCVReturnSuccess, let output else { throw InputError("无法分配录制缓存：\(status)") }
        guard CVPixelBufferGetWidth(source) == CVPixelBufferGetWidth(output),
              CVPixelBufferGetHeight(source) == CVPixelBufferGetHeight(output) else { throw InputError("录制过程中图像尺寸发生变化。") }
        CVBufferRemoveAllAttachments(output)
        CVBufferPropagateAttachments(source, output)
        // Release command/texture wrappers before returning the camera's sample.
        try autoreleasepool { try blit(source, to: output) }
        CVMetalTextureCacheFlush(cache, 0)
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr else {
            throw InputError("无法读取录制帧时间戳。")
        }
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: output,
            formatDescription: description, sampleTiming: &timing, sampleBufferOut: &result) == noErr, let result else {
            throw InputError("无法封装录制帧。")
        }
        CMPropagateAttachments(sample, destination: result)
        copiedFrames += 1
        return result
    }

    private func blit(_ source: CVPixelBuffer, to output: CVPixelBuffer) throws {
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeBlitCommandEncoder() else {
            throw InputError("无法创建录制 GPU 命令。")
        }
        var textures: [CVMetalTexture] = []
        for plane in 0..<2 {
            var pair: [MTLTexture] = []
            for buffer in [source, output] {
                var texture: CVMetalTexture?
                let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil,
                    plane == 0 ? .r8Unorm : .rg8Unorm,
                    CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &texture)
                guard status == kCVReturnSuccess, let texture, let metal = CVMetalTextureGetTexture(texture) else {
                    encoder.endEncoding()
                    throw InputError("无法映射录制纹理：\(status)")
                }
                textures.append(texture); pair.append(metal)
            }
            encoder.copy(from: pair[0], to: pair[1])
        }
        encoder.endEncoding()
        withExtendedLifetime(textures) { command.commit(); command.waitUntilCompleted() }
        guard command.status == .completed else { throw command.error ?? InputError("录制 GPU 复制失败。") }
    }
}
