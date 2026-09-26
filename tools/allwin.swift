import Cocoa
guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String:Any]] else { exit(1) }
var found = 0
for i in list {
  let owner = i[kCGWindowOwnerName as String] as? String ?? "?"
  guard owner.lowercased().contains("lumina") else { continue }
  found += 1
  let num = i[kCGWindowNumber as String] as? Int ?? -1
  let layer = i[kCGWindowLayer as String] as? Int ?? 0
  let on = i[kCGWindowIsOnscreen as String] as? Bool ?? false
  var b = "?"
  if let d = i[kCGWindowBounds as String] as? [String:Any], let r = CGRect(dictionaryRepresentation: d as CFDictionary) {
    b = "\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.width))x\(Int(r.height))"
  }
  print("  id=\(num) layer=\(layer) onscreen=\(on) \(b)")
}
print("共 \(found) 个 Lumina 窗口")
