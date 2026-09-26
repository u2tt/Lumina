import Cocoa
import ScreenCaptureKit

// 高频抓取指定窗口（不受其它窗口遮挡），统计"接近全黑"的采样点。
// 切换时闪一下 = 中间有若干次采样全黑。
// 用法: flashdetect <windowid> <秒数>

func syncShareable() -> SCShareableContent? {
    let sem = DispatchSemaphore(value: 0)
    var out: SCShareableContent?
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { c, _ in
        out = c; sem.signal()
    }
    sem.wait()
    return out
}

func syncCapture(_ filter: SCContentFilter, _ cfg: SCStreamConfiguration) -> CGImage? {
    let sem = DispatchSemaphore(value: 0)
    var out: CGImage?
    SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { img, _ in
        out = img; sem.signal()
    }
    sem.wait()
    return out
}

func lum(_ img: CGImage) -> Double {
    let w = 60, h = 40
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var s = 0.0
    for i in stride(from: 0, to: buf.count, by: 4) {
        s += (Double(buf[i]) + Double(buf[i+1]) + Double(buf[i+2])) / 3
    }
    return s / Double(w * h * 255)
}

// ⚠️ 命令行工具必须先建立 WindowServer 连接，否则 ScreenCaptureKit 会
//    触发 CGS_REQUIRE_INIT 断言直接崩掉。
_ = NSApplication.shared
_ = CGMainDisplayID()

let wid = UInt32(CommandLine.arguments[1])!
let seconds = Double(CommandLine.arguments[2]) ?? 8

guard let content = syncShareable(),
      let win = content.windows.first(where: { $0.windowID == wid }) else {
    print("找不到窗口 \(wid)"); exit(1)
}
let filter = SCContentFilter(desktopIndependentWindow: win)
let cfg = SCStreamConfiguration()
cfg.width = 32
cfg.height = 20
cfg.showsCursor = false

let start = CACurrentMediaTime()
var samples: [(Double, Double)] = []
while CACurrentMediaTime() - start < seconds {
    if let img = syncCapture(filter, cfg) {
        samples.append((CACurrentMediaTime() - start, lum(img)))
    }
}

guard samples.count > 5 else { print("采样过少（\(samples.count)）"); exit(1) }
let lums = samples.map(\.1)
let avg = lums.reduce(0,+) / Double(lums.count)
print(String(format: "采样 %d 次 / %.1fs（约 %.0f 次/秒）  平均亮度 %.4f  最暗 %.4f",
             samples.count, seconds, Double(samples.count)/seconds, avg, lums.min()!))

let thresh = max(0.006, avg * 0.25)
let blacks = samples.filter { $0.1 < thresh }
print(String(format: "接近全黑：%d 次（阈值 <%.4f）", blacks.count, thresh))
for (t, l) in blacks.prefix(20) { print(String(format: "  t=%.3fs  亮度 %.4f", t, l)) }
// 列出黑帧前后各 3 个采样的亮度，判断是"掉一下"还是"持续一段"
if let firstBlack = samples.firstIndex(where: { $0.1 < thresh }) {
    let lo = max(0, firstBlack - 3), hi = min(samples.count - 1, firstBlack + 5)
    print("黑帧附近（t / 亮度）：")
    for i in lo...hi {
        let mark = i == firstBlack ? " ← 黑" : ""
        print(String(format: "  t=%.3fs  %.4f%@", samples[i].0, samples[i].1, mark))
    }
}
var line = "  "
for l in lums { line += l < thresh ? "X" : (l < avg * 0.6 ? "-" : "#") }
print("亮度曲线（X=黑）:"); print(line)
