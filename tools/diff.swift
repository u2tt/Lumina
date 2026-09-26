import Cocoa
func px(_ p: String) -> NSBitmapImageRep? {
  guard let i = NSImage(contentsOfFile: p), let t = i.tiffRepresentation else { return nil }
  return NSBitmapImageRep(data: t)
}
guard let a = px(CommandLine.arguments[1]), let b = px(CommandLine.arguments[2]) else { exit(1) }
var changed = 0, n = 0, maxd = 0.0
for j in stride(from:0, to:a.pixelsHigh, by:8) { for i in stride(from:0, to:a.pixelsWide, by:8) {
  guard let ca = a.colorAt(x:i,y:j), let cb = b.colorAt(x:i,y:j) else { continue }
  n += 1
  let d = abs(ca.redComponent-cb.redComponent) + abs(ca.greenComponent-cb.greenComponent) + abs(ca.blueComponent-cb.blueComponent)
  if d > 0.02 { changed += 1 }
  maxd = max(maxd, d)
}}
print(String(format:"两帧间变化像素占比 %.1f%%  最大色差 %.3f  (采样 %d)", Double(changed)/Double(n)*100, maxd, n))
