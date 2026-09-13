import Foundation
import CoreMedia
import CoreVideo

/// Host-side verification of the exact Metal copy used by the recording writer.
/// CPU pixel access below belongs to the test oracle, not to the app's capture path.
@main struct CaptureBufferValidation {
    static func main() throws {
        for (width, height) in [(1280, 720), (3840, 2160)] {
            try autoreleasepool { try verify(width: width, height: height) }
        }
        print("Capture Metal copy passed: exact Y/UV, original PTS/duration/attachments, bounded pool and reuse")
    }
    static func verify(width: Int, height: Int) throws {
        var source: CVPixelBuffer?
        let attrs = [kCVPixelBufferMetalCompatibilityKey as String: true,
                     kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as [String: Any]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            attrs as CFDictionary, &source) == 0, let source else { throw InputError("Test allocation failed") }
        CVPixelBufferLockBaseAddress(source, [])
        for plane in 0..<2 {
            let p = CVPixelBufferGetBaseAddressOfPlane(source, plane)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            for y in 0..<CVPixelBufferGetHeightOfPlane(source, plane) {
                for x in 0..<(CVPixelBufferGetWidthOfPlane(source, plane) * (plane+1)) {
                    p[y*stride+x] = UInt8((x + 13*y + 73*plane) % 256)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(source, [])
        CVBufferSetAttachment(source, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: source,
            formatDescriptionOut: &description) == 0, let description else { throw InputError("Test format failed") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: 9_999_123_457, timescale: 1_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: source, formatDescription: description,
            sampleTiming: &timing, sampleBufferOut: &sample) == 0, let sample else { throw InputError("Test sample failed") }
        let marker = "capture-copy-test" as CFString
        CMSetAttachment(sample, key: marker, value: "preserved" as CFString, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        let copier = try CaptureBufferCopier(width: width, height: height)
        var held: [CMSampleBuffer] = []
        for _ in 0..<CaptureBufferCopier.capacity {
            guard let result = try autoreleasepool(invoking: { try copier.copy(sample) }),
                  let pixel = CMSampleBufferGetImageBuffer(result) else { throw InputError("Test copy failed") }
            guard pixel !== source, CMSampleBufferGetPresentationTimeStamp(result) == timing.presentationTimeStamp,
                  CMSampleBufferGetDuration(result) == timing.duration,
                  CMGetAttachment(result, key: marker, attachmentModeOut: nil) as? String == "preserved",
                  CVBufferCopyAttachment(pixel, kCVImageBufferColorPrimariesKey, nil) as? String == kCVImageBufferColorPrimaries_ITU_R_709_2 as String else {
                throw InputError("Copy changed identity, time or attachments")
            }
            CVPixelBufferLockBaseAddress(source, .readOnly); CVPixelBufferLockBaseAddress(pixel, .readOnly)
            for plane in 0..<2 {
                let a = CVPixelBufferGetBaseAddressOfPlane(source, plane)!
                let b = CVPixelBufferGetBaseAddressOfPlane(pixel, plane)!
                for y in 0..<CVPixelBufferGetHeightOfPlane(source, plane) {
                    guard memcmp(a + y*CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                        b + y*CVPixelBufferGetBytesPerRowOfPlane(pixel, plane), width) == 0 else { throw InputError("Pixel mismatch") }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixel, .readOnly); CVPixelBufferUnlockBaseAddress(source, .readOnly)
            held.append(result)
        }
        guard try copier.copy(sample) == nil else { throw InputError("Pool exceeded its bound") }
        held.removeAll()
        guard try autoreleasepool(invoking: { try copier.copy(sample) }) != nil else { throw InputError("Pool did not recycle buffers") }
    }
}
