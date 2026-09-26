#!/usr/bin/env swift
// ============================================================
//  生成 Lumina 应用图标 (AppIcon.icns)
//  用法: swift build/make_icon.swift
//  无第三方依赖，纯 CoreGraphics 绘制
// ============================================================
import Cocoa
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
let outDir = root.appendingPathComponent("build")
let icnsURL = outDir.appendingPathComponent("AppIcon.icns")

try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// 画一张图标位图
func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    defer { img.unlockFocus() }

    guard let ctx = NSGraphicsContext.current?.cgContext else { return img }
    let s = size

    // ---- 圆角矩形裁剪（macOS 图标安全区：四周留 ~8%）----
    let inset = s * 0.06
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = (s - inset * 2) * 0.2237          // macOS "squircle" 近似
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // ---- 底色：深空渐变 ----
    let cs = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        CGColor(srgbRed: 0.04, green: 0.06, blue: 0.13, alpha: 1),
        CGColor(srgbRed: 0.02, green: 0.02, blue: 0.05, alpha: 1)
    ] as CFArray
    if let grad = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    }

    // ---- 极光丝带：多层曲线 ----
    func auroraBand(_ yy: CGFloat, _ amp: CGFloat, _ freq: CGFloat, _ phase: CGFloat,
                    _ colors: [CGColor], alpha: CGFloat) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + yy))
        var x = rect.minX
        while x <= rect.maxX {
            let t = (x - rect.minX) / rect.width
            let y = rect.minY + yy
                  + sin(t * freq + phase) * amp
                  + sin(t * freq * 2.3 + phase * 1.7) * amp * 0.4
            p.addLine(to: CGPoint(x: x, y: y))
            x += rect.width / 120
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.closeSubpath()

        ctx.saveGState()
        ctx.addPath(p)
        ctx.clip()
        if let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g,
                start: CGPoint(x: rect.midX, y: rect.maxY),
                end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        }
        ctx.restoreGState()
    }

    // 三条不同色相的极光带
    auroraBand(rect.height * 0.44, rect.height * 0.10, 2.1, 0.4,
               [CGColor(srgbRed: 0.16, green: 0.95, blue: 0.72, alpha: 0.95),
                CGColor(srgbRed: 0.10, green: 0.75, blue: 0.85, alpha: 0.95)], alpha: 0.95)
    auroraBand(rect.height * 0.58, rect.height * 0.13, 1.6, 2.1,
               [CGColor(srgbRed: 0.34, green: 0.48, blue: 1.0, alpha: 0.95),
                CGColor(srgbRed: 0.18, green: 0.22, blue: 0.85, alpha: 0.95)], alpha: 0.85)
    auroraBand(rect.height * 0.72, rect.height * 0.09, 2.7, 4.3,
               [CGColor(srgbRed: 0.85, green: 0.38, blue: 0.95, alpha: 0.95),
                CGColor(srgbRed: 0.55, green: 0.20, blue: 0.85, alpha: 0.95)], alpha: 0.70)

    // ---- 星点 ----
    var seed: UInt64 = 0x9E3779B97F4A7C15
    func rnd() -> CGFloat {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
        return CGFloat(seed % 10000) / 10000.0
    }
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    for _ in 0..<52 {
        let x = rect.minX + rnd() * rect.width
        let y = rect.minY + rect.height * (0.48 + rnd() * 0.52)   // 上半部
        let r = s * (0.0018 + rnd() * 0.0035)
        let a = 0.25 + rnd() * 0.7
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: a))
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    ctx.restoreGState()

    // ---- 内描边，让图标在浅色背景上也有边界 ----
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10))
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.strokePath()
    ctx.restoreGState()

    return img
}

// ---- 输出 iconset 各尺寸 ----
let specs: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, px) in specs {
    let img = drawIcon(size: px)
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("生成 \(name) 失败\n".data(using: .utf8)!)
        exit(1)
    }
    try! png.write(to: iconset.appendingPathComponent(name))
}

// ---- iconset -> icns ----
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", icnsURL.path]
try! p.run()
p.waitUntilExit()

if p.terminationStatus == 0 {
    let size = ((try? FileManager.default.attributesOfItem(atPath: icnsURL.path))?[.size] as? Int) ?? 0
    print("✓ 已生成 \(icnsURL.path) (\(size) 字节)")
} else {
    FileHandle.standardError.write("iconutil 失败，退出码 \(p.terminationStatus)\n".data(using: .utf8)!)
    exit(1)
}
