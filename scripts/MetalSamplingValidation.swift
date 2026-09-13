// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone GPU pixel oracle and microbenchmark. CPU access is test-only.
import Foundation
import CoreVideo
import Metal
struct InputError: Error { let message: String; init(_ s: String) { message=s } }
@main struct MetalSamplingValidation {
 static func buffer(_ w:Int,_ h:Int) throws -> CVPixelBuffer {
  var b:CVPixelBuffer?; let attrs:[String:Any]=[kCVPixelBufferIOSurfacePropertiesKey as String:[:],kCVPixelBufferMetalCompatibilityKey as String:true]
  guard CVPixelBufferCreate(nil,w,h,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,attrs as CFDictionary,&b)==0,let b else { throw InputError("alloc") }; return b
 }
 static func main() throws {
  let device=MTLCreateSystemDefaultDevice()!
  let lib=try device.makeLibrary(URL:URL(fileURLWithPath:CommandLine.arguments[1]))
  let a=try MetalStabilizer(library:lib,referenceSampling:true),b=try MetalStabilizer(library:lib)
  let source=try buffer(3840,2160),outA=try buffer(2816,1584),outB=try buffer(2816,1584)
  CVPixelBufferLockBaseAddress(source,[])
  for plane in 0..<2 {
   let ptr=CVPixelBufferGetBaseAddressOfPlane(source,plane)!.assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRowOfPlane(source,plane)
   for y in 0..<CVPixelBufferGetHeightOfPlane(source,plane) {for x in 0..<(CVPixelBufferGetWidthOfPlane(source,plane)*(plane+1)) {ptr[y*stride+x]=UInt8((x*19+y*73+(x*y)%131)%256)}}
  }
  CVPixelBufferUnlockBaseAddress(source,[])
  let warps:[[Float]] = [[1,0,0,0,0,1,0,0,0,0,1,0],[1.24,0.063,-13.3125,0,-0.027,1.14,5.4375,0,0.00001,-0.000007,1,0],[0.91,-0.22,12.03,0,0.16,0.84,-4.47,0,0,0,1,0],[1,0,-5000,0,0,1,0,0,0,0,1,0]]
  var maximum=0,total=0,n=0
  for rows in warps {
   _=try a.submit(source:source,output:outA,rows:rows).finish();_=try b.submit(source:source,output:outB,rows:rows).finish()
   CVPixelBufferLockBaseAddress(outA,.readOnly);CVPixelBufferLockBaseAddress(outB,.readOnly)
   for plane in 0..<2 {
    let pa=CVPixelBufferGetBaseAddressOfPlane(outA,plane)!.assumingMemoryBound(to:UInt8.self),pb=CVPixelBufferGetBaseAddressOfPlane(outB,plane)!.assumingMemoryBound(to:UInt8.self)
    for y in 0..<CVPixelBufferGetHeightOfPlane(outA,plane) { for x in 0..<(CVPixelBufferGetWidthOfPlane(outA,plane)*(plane+1)) {
     let delta=abs(Int(pa[y*CVPixelBufferGetBytesPerRowOfPlane(outA,plane)+x])-Int(pb[y*CVPixelBufferGetBytesPerRowOfPlane(outB,plane)+x]));maximum=max(maximum,delta);total+=delta;n+=1
    }}
   }
   CVPixelBufferUnlockBaseAddress(outB,.readOnly);CVPixelBufferUnlockBaseAddress(outA,.readOnly)
  }
  print("pixels max=\(maximum) mean=\(Double(total)/Double(n)) samples=\(n)")
  guard maximum<=1 else { throw InputError("pixels") }
  for (name,renderer,out) in [("reference",a,outA),("optimized",b,outB),("reference",a,outA),("optimized",b,outB)] {
   var times:[Double]=[]
   for _ in 0..<24 { times.append(try autoreleasepool { try renderer.submit(source:source,output:out,rows:warps[1]).finish() }) }
   print(name,"GPU ms/frame",times.sorted()[times.count/2]*1000)
  }
 }
}
