// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import Foundation

/// A known tilted horizon, sent through the real core and native Metal renderer.
enum HorizonPixelValidation {
    static func run() throws {
        let renderer = try MetalStabilizer()
        func buffer() throws -> CVPixelBuffer {
            var pixel: CVPixelBuffer?
            let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true] as [String: Any]
            guard CVPixelBufferCreate(nil,640,360,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,attrs as CFDictionary,&pixel) == 0, let pixel else { throw InputError("Cannot allocate horizon fixture") }
            return pixel
        }
        for rotation in [0,90,180,270] {
            for tilt in [-20.0, 20.0] {
                let angle = (Double(rotation)+tilt) * .pi/180
                let times = (-5..<110).map { Double($0)*10 }
                let config: [String: Any] = ["width":640,"height":360,"output_width":640,"output_height":360,
                    "duration_ms":1000,"fps":30,"display_rotation_degrees":rotation,
                    "options":["smoothingSeconds":0,"horizonLock":true,"allowBlackBorders":true,"dynamicCrop":false,"maxCrop":1],
                    "frames":(0..<30).map { ["timestamp_us":$0*33333,"k":[500,0,320,0,500,180,0,0,1]] as [String: Any] },
                    "gyro":times.map { ["timestamp_ms":$0,"gyro":[0,0,0]] as [String: Any] },
                    "gravity":times.map { ["timestamp_ms":$0,"gravity":[-cos(angle),-sin(angle),0]] as [String: Any] }]
                let json = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
                var error = [CChar](repeating: 0, count: 2048)
                guard let engine = json.withCString({ mc_engine_create($0, &error, error.count) }) else { throw InputError(String(cString: error)) }
                defer { mc_engine_destroy(engine) }
                var rows = [Float](repeating: 0, count: 12)
                guard mc_engine_transform(engine, 500000, &rows, rows.count) == 0 else { throw InputError("Horizon warp failed") }
                let source = try buffer(), output = try buffer()
                CVPixelBufferLockBaseAddress(source, [])
                let luma = CVPixelBufferGetBaseAddressOfPlane(source,0)!.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(source,0)
                for y in 0..<360 { for x in 0..<640 {
                    // The horizon is perpendicular to projected gravity.
                    let distance = Double(x-320)*sin(angle)+Double(y-180)*cos(angle)
                    luma[y*stride+x] = abs(distance) < 3 ? 235 : 70
                }}
                let uv = CVPixelBufferGetBaseAddressOfPlane(source,1)!.assumingMemoryBound(to: UInt8.self)
                uv.initialize(repeating:128,count:CVPixelBufferGetBytesPerRowOfPlane(source,1)*180)
                CVPixelBufferUnlockBaseAddress(source, [])
                let frame = try renderer.submit(source: source, output: output, rows: rows)
                _ = try frame.finish()
                CVPixelBufferLockBaseAddress(output, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
                let pixels = CVPixelBufferGetBaseAddressOfPlane(output,0)!.assumingMemoryBound(to: UInt8.self)
                let outputStride = CVPixelBufferGetBytesPerRowOfPlane(output,0)
                let beta = Double(rotation) * .pi/180
                for along in [-80.0, 0, 80] {
                    for across in [0.0, 20] {
                        // In the displayed movie this is a horizontal stripe. The
                        // native buffer intentionally retains the inverse quarter turn.
                        let x = Int((320+along*cos(beta)+across*sin(beta)).rounded())
                        let y = Int((180-along*sin(beta)+across*cos(beta)).rounded())
                        let value = Int(pixels[y*outputStride+x])
                        guard across == 0 ? value > 215 : abs(value-70) <= 3 else {
                            throw InputError("Gravity horizon pixel failure: rotation=\(rotation), tilt=\(tilt), value=\(value)")
                        }
                    }
                }
                print("PASS Metal gravity horizon: display \(rotation)°, tilt \(tilt)°")
            }
        }
    }
}
