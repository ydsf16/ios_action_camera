// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import Metal
import Foundation

enum MetalPixelValidation {
    static func run() throws {
        let renderer = try MetalStabilizer()
        func buffer(_ width: Int, _ height: Int) throws -> CVPixelBuffer {
            var result: CVPixelBuffer?
            let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true] as [String: Any]
            guard CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,attrs as CFDictionary,&result) == 0, let result else { throw InputError("test allocation failed") }
            return result
        }
        let source = try buffer(640,360)
        CVPixelBufferLockBaseAddress(source, [])
        for plane in 0..<2 {
            let ptr = CVPixelBufferGetBaseAddressOfPlane(source,plane)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(source,plane)
            for y in 0..<CVPixelBufferGetHeightOfPlane(source,plane) { for x in 0..<CVPixelBufferGetWidthOfPlane(source,plane) {
                if plane == 0 { ptr[y*stride+x] = UInt8(16+x/4+y/8) }
                else { ptr[y*stride+2*x] = UInt8(64+x/4); ptr[y*stride+2*x+1] = UInt8(144+y/4) }
            }}
        }
        CVPixelBufferUnlockBaseAddress(source, [])
        CVBufferSetAttachment(source,kCVImageBufferChromaLocationTopFieldKey,kCVImageBufferChromaLocation_Left,.shouldPropagate)
        var pending: [(MetalStabilizer.Frame, Float, Float, Float)] = []
        for (scale,tx,ty) in [(Float(1),Float(0),Float(0)),(1,24,16),(2,0,0),(1,1000,0)] {
            let output = try buffer(320,180)
            let rows: [Float] = [scale,0,tx,0,0,scale,ty,0,0,0,1,0]
            pending.append((try renderer.submit(source:source,output:output,rows:rows),scale,tx,ty))
        }
        for (frame,scale,tx,ty) in pending {
            _ = try frame.finish()
            CVPixelBufferLockBaseAddress(frame.output,.readOnly)
            defer { CVPixelBufferUnlockBaseAddress(frame.output,.readOnly) }
            for plane in 0..<2 {
                let ptr = CVPixelBufferGetBaseAddressOfPlane(frame.output,plane)!.assumingMemoryBound(to:UInt8.self)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(frame.output,plane)
                let x = 40, y = 32
                let sx = Float(x)*scale + tx/Float(plane+1)
                let sy = Float(y)*scale + ty/Float(plane+1)
                let expected: [Int]
                if tx > 640 { expected = plane == 0 ? [16] : [128,128] }
                else if plane == 0 { expected = [16+Int(sx)/4+Int(sy)/8] }
                else { expected = [64+Int(sx)/4,144+Int(sy)/4] }
                for (channel,value) in expected.enumerated() {
                    let actual = Int(ptr[y*stride+x*(plane+1)+channel])
                    guard abs(actual-value) <= 1 else { throw InputError("plane=\(plane) scale=\(scale) tx=\(tx) value=\(actual) expected=\(value)") }
                }
            }
        }
        print("Metal NV12 pixels passed: identity, translation, downscale, black Y/UV, multiple in-flight frames")
    }
}
