// Render App Store layouts around unmodified, actual app screenshots.
// Run from the repository root: swift scripts/render_store_screenshots.swift
import AppKit
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("docs/app-store/screenshots")
let W = 1284, H = 2778
func color(_ hex: UInt32) -> NSColor { NSColor(srgbRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1) }
func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x:x,y:CGFloat(H)-y-h,width:w,height:h) }
func text(_ string: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, ink: NSColor = .white) {
 let p = NSMutableParagraphStyle(); p.lineSpacing = 5
 (string as NSString).draw(in:box(x,y,width,height), withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:ink,.paragraphStyle:p])
}
struct Card { let file: String; let source: String; let label: String; let title: String; let subtitle: String; let footnote: String; let accent: UInt32 }
let cards = [
 Card(file:"01-playback.png",source:"raw/playback.png",label:"全屏回看",title:"拍完以后，\n再选稳定感。",subtitle:"原片保留，随时调整与导出。",footnote:"实际应用界面 · 风景为 AI 生成的演示素材",accent:0x46DAC6),
 Card(file:"02-simple.png",source:"raw/simple.png",label:"轻松设置",title:"三档稳定，\n一点就好。",subtitle:"自然 / 标准 / 强力 · 支持重力水平锁定",footnote:"生成前选择 1080p 或 2.8K 输出",accent:0x6AABF5),
 Card(file:"03-controls.png",source:"raw/advanced.png",label:"高级控制",title:"视野与裁切，\n由你决定。",subtitle:"动态缩放、裁切上限、允许黑边。",footnote:"稳定效果取决于素材、光线和所选参数",accent:0xB29AF8),
 Card(file:"04-unlock.png",source:"iap-review.png",label:"免费开始",title:"先免费拍，\n再决定。",subtitle:"每段 1 分钟免费 · 长时间录制一次买断",footnote:"免费不限次数 · 稳定与导出无水印 · 无订阅",accent:0x46DAC6)
]
try FileManager.default.createDirectory(at: root.appendingPathComponent("store"), withIntermediateDirectories:true)
for (index,card) in cards.enumerated() {
 guard let cg = CGContext(data:nil,width:W,height:H,bitsPerComponent:8,bytesPerRow:W*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue), let screen=NSImage(contentsOf:root.appendingPathComponent(card.source)), let icon=NSImage(contentsOf:URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("docs/site/icon.png")) else { fatalError("Missing screenshot asset") }
 let context=NSGraphicsContext(cgContext:cg,flipped:false)
 NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
 NSGradient(starting:color(0x142737),ending:color(0x080D17))!.draw(in:NSRect(x:0,y:0,width:W,height:H),angle:270)
 let accent=color(card.accent)
 icon.draw(in:box(80,77,66,66));text("RoamShot",164,83,440,70,size:43,weight:.semibold)
 text(String(format:"%02d",index+1)+" / 04",1072,96,160,50,size:27,weight:.medium,ink:color(0x8BA2B3))
 text(card.label,80,199,1100,70,size:31,weight:.semibold,ink:accent)
 text(card.title,74,273,1150,244,size:99,weight:.bold)
 text(card.subtitle,82,541,1120,68,size:35,weight:.medium,ink:color(0xB5C8D5))
 let sw:CGFloat=938, sh=sw*screen.size.height/screen.size.width, sx=(CGFloat(W)-sw)/2, sy:CGFloat=643
 let frame=box(sx-11,sy-11,sw+22,sh+22)
 NSGraphicsContext.saveGraphicsState()
 let shadow=NSShadow();shadow.shadowColor = .black.withAlphaComponent(0.45);shadow.shadowBlurRadius=45;shadow.shadowOffset=NSSize(width:0,height:-18);shadow.set()
 color(0x2C3E50).setFill();NSBezierPath(roundedRect:frame,xRadius:51,yRadius:51).fill()
 NSGraphicsContext.restoreGraphicsState()
 NSGraphicsContext.saveGraphicsState()
 NSBezierPath(roundedRect:box(sx,sy,sw,sh),xRadius:43,yRadius:43).addClip()
 screen.draw(in:box(sx,sy,sw,sh))
 NSGraphicsContext.restoreGraphicsState()
 accent.withAlphaComponent(0.45).setStroke();let border=NSBezierPath(roundedRect:frame,xRadius:51,yRadius:51);border.lineWidth=2;border.stroke()
 text(card.footnote,82,2710,1130,52,size:26,weight:.regular,ink:color(0x9AABB9))
 NSGraphicsContext.restoreGraphicsState()
 guard let output=cg.makeImage(), let png=NSBitmapImageRep(cgImage:output).representation(using:.png,properties:[:]) else {fatalError("PNG rendering failed")}
 try png.write(to:root.appendingPathComponent("store").appendingPathComponent(card.file))
 print(card.file)
}

// Compact review sheet; full-size uploads remain separate and unchanged.
let previewW=1360, previewH=750
let previewCG=CGContext(data:nil,width:previewW,height:previewH,bitsPerComponent:8,bytesPerRow:previewW*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:previewCG,flipped:false)
color(0x0B1420).setFill();NSRect(x:0,y:0,width:previewW,height:previewH).fill()
for (i,c) in cards.enumerated() {
 let img=NSImage(contentsOf:root.appendingPathComponent("store").appendingPathComponent(c.file))!
 img.draw(in:NSRect(x:CGFloat(24+i*334),y:28,width:310,height:CGFloat(2778)*310/1284))
}
NSGraphicsContext.restoreGraphicsState()
try NSBitmapImageRep(cgImage:previewCG.makeImage()!).representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("overview.png"))
