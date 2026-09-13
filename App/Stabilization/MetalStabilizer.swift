// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import CoreVideo
import CoreMedia
import Foundation

/// IOSurface-backed NV12 in/out. No CPU pixel mapping, upload, readback or RGB conversion.
final class MetalStabilizer {
    struct Warp { var row0, row1, row2, plane: SIMD4<Float> }
    final class Frame {
        let command: MTLCommandBuffer
        let source, output: CVPixelBuffer
        let textures: [CVMetalTexture]
        init(_ command: MTLCommandBuffer, _ source: CVPixelBuffer, _ output: CVPixelBuffer, _ textures: [CVMetalTexture]) {
            self.command = command; self.source = source; self.output = output; self.textures = textures
        }
        func finish() throws -> Double {
            command.waitUntilCompleted()
            guard command.status == .completed else { throw command.error ?? InputError("Metal 渲染失败，原片已保留。") }
            return max(0, command.gpuEndTime - command.gpuStartTime)
        }
        deinit { command.waitUntilCompleted() } // Hold CV textures AND buffers through GPU completion.
    }
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    let kernelName: String
    private var cache: CVMetalTextureCache
    init(library: MTLLibrary? = nil, referenceSampling: Bool = false) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw InputError("Metal 不可用。") }
        self.device = device; self.queue = queue
        kernelName = referenceSampling ? "warpPlaneReference" : "warpPlane"
        guard let function = (library ?? device.makeDefaultLibrary())?.makeFunction(name: kernelName) else { throw InputError("找不到稳定着色器。") }
        pipeline = try device.makeComputePipelineState(function: function)
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { throw InputError("无法创建 Metal 纹理缓存。") }
        self.cache = cache
    }
    private func chromaOffset(_ buffer: CVPixelBuffer) throws -> SIMD2<Float> {
        let value = CVBufferCopyAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, nil) as? String
        // Unspecified 4:2:0 uses centered chroma; propagate explicit siting to the encoder.
        if value == nil || value == (kCVImageBufferChromaLocation_Center as String) { return SIMD2(0.5, 0.5) }
        if value == (kCVImageBufferChromaLocation_Left as String) { return SIMD2(0, 0.5) }
        if value == (kCVImageBufferChromaLocation_TopLeft as String) { return SIMD2(0, 0) }
        if value == (kCVImageBufferChromaLocation_Top as String) { return SIMD2(0.5, 0) }
        if value == (kCVImageBufferChromaLocation_BottomLeft as String) { return SIMD2(0, 1) }
        if value == (kCVImageBufferChromaLocation_Bottom as String) { return SIMD2(0.5, 1) }
        throw InputError("不支持的色度采样位置。")
    }
    func submit(source: CVPixelBuffer, output: CVPixelBuffer, rows: [Float]) throws -> Frame {
        guard rows.count == 12, rows.allSatisfy(\.isFinite),
              CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(source) == 2, CVPixelBufferGetPlaneCount(output) == 2 else { throw InputError("稳定处理需要 NV12 视频缓存。") }
        CVBufferPropagateAttachments(source, output)
        let offset = try chromaOffset(source)
        CVBufferSetAttachment(output, kCVImageBufferChromaLocationTopFieldKey,
            CVBufferCopyAttachment(source, kCVImageBufferChromaLocationTopFieldKey, nil) ?? kCVImageBufferChromaLocation_Center, .shouldPropagate)
        // A crop changes pixel coordinates, so capture intrinsics must not describe the output.
        CVBufferRemoveAttachment(output, kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix)
        CVBufferRemoveAttachment(output, kCVImageBufferCleanApertureKey)
        CVBufferRemoveAttachment(output, kCVImageBufferDisplayDimensionsKey)
        guard let command = queue.makeCommandBuffer() else { throw InputError("无法创建 GPU 命令。") }
        var textures: [CVMetalTexture] = []
        for plane in 0..<2 {
            var pair: [MTLTexture] = []
            for buffer in [source, output] {
                var texture: CVMetalTexture?
                let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil,
                    plane == 0 ? .r8Unorm : .rg8Unorm,
                    CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &texture)
                guard status == kCVReturnSuccess, let texture, let metal = CVMetalTextureGetTexture(texture) else { throw InputError("无法映射 Metal 纹理：\(status)") }
                textures.append(texture); pair.append(metal)
            }
            guard let encoder = command.makeComputeCommandEncoder() else { throw InputError("无法创建 GPU 编码器。") }
            var warp = Warp(row0: SIMD4(rows[0],rows[1],rows[2],0), row1: SIMD4(rows[4],rows[5],rows[6],0),
                            row2: SIMD4(rows[8],rows[9],rows[10],0), plane: plane == 0 ? SIMD4(1,0,0,0) : SIMD4(2,offset.x,offset.y,0))
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(pair[0], index: 0); encoder.setTexture(pair[1], index: 1)
            encoder.setBytes(&warp, length: MemoryLayout<Warp>.stride, index: 0)
            encoder.dispatchThreads(MTLSize(width: pair[1].width,height: pair[1].height,depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16,height: 8,depth: 1))
            encoder.endEncoding()
        }
        let frame = Frame(command,source,output,textures)
        command.commit()
        return frame
    }
}
