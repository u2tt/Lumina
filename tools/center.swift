import Cocoa
guard let img = NSImage(contentsOfFile: CommandLine.arguments[1]), let t = img.tiffRepresentation,
      let r = NSBitmapImageRep(data: t) else { exit(1) }
// 取中心区域平均，避开边缘
let cx = r.pixelsWide/2, cy = r.pixelsHigh/2
var R=0.0,G=0.0,B=0.0,n=0.0
for j in stride(from:cy-100,to:cy+100,by:20) { for i in stride(from:cx-100,to:cx+100,by:20) {
  guard let c = r.colorAt(x:i,y:j) else { continue }
  R+=c.redComponent; G+=c.greenComponent; B+=c.blueComponent; n+=1
}}
print(String(format:"中心色 R=%.2f G=%.2f B=%.2f", R/n, G/n, B/n))
