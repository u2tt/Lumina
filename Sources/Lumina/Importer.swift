import Cocoa
import UniformTypeIdentifiers

// ============================================================
//  视频选择
//  菜单栏和设置窗口共用同一套逻辑，避免两处行为不一致
//
//  选择器**文件和文件夹都可以选**：
//    · 选文件   → 直接用它
//    · 选文件夹 → 取里面的视频（按文件名排序取第一个；at most 一个，
//                 因为本 app 是单视频模式，不做轮播）
// ============================================================

enum VideoImporter {

    /// 认作视频的扩展名。AVFoundation 能解的都放进来，
    /// 具体能不能播由 AVPlayer 决定 —— 这里只是别让明显不是视频的混进来。
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg",
        "wmv", "flv", "ts", "m2ts", "3gp", "ogv", "dv"
    ]

    static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// 列出目录里的视频文件（不递归子目录，按文件名自然排序）。
    /// 用于"选了文件夹"的情形。
    static func videos(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        return items
            .filter { url in
                guard isVideo(url) else { return false }
                let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                return isFile && fm.isReadableFile(atPath: url.path)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// 弹出选择面板。文件与文件夹都能选。返回 nil 表示用户取消。
    ///
    /// ⚠️ 选中文件夹时不再返回"一堆视频" —— 本 app 是单视频模式，
    ///    只取排序后的第一个，避免一次塞进 155 个 Aerial 素材。
    static func pickFiles() -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true          // 文件夹也可以选
        panel.treatsFilePackagesAsDirectories = false
        // ⚠️ 不设 allowedContentTypes：一旦设了，NSOpenPanel 会禁止选择文件夹。
        //    过滤交给下面的 isVideo / videos(in:) 自己做。
        panel.message = "选择视频；或选择文件夹，将轮播其中所有视频"
        panel.prompt = "确定"
        // 默认打开到内置 Aerial 素材所在目录
        panel.directoryURL = Settings.defaultVideoDirectory

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let picked = panel.urls.first else { return nil }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: picked.path, isDirectory: &isDir) else {
            Log.warn("选中的路径不存在：\(picked.path)")
            return nil
        }

        if isDir.boolValue {
            // 选了文件夹 → 取里面的视频
            let found = videos(in: picked)
            guard !found.isEmpty else {
                Log.warn("文件夹里没有找到视频：\(picked.path)")
                alertNoVideo(in: picked)
                return nil
            }
            // ★ 选了文件夹就播这一整个文件夹，播完一个自动切下一个。
            Log.info("选中文件夹 → 播放其中 \(found.count) 个视频\(found.count > 1 ? "（轮播）" : "")")
            return found
        }

        // 选了文件
        guard FileManager.default.isReadableFile(atPath: picked.path) else {
            Log.warn("选中的文件不可读：\(picked.path)")
            return nil
        }
        guard isVideo(picked) else {
            Log.warn("选中的不是视频文件：\(picked.lastPathComponent)")
            alertNotVideo(picked)
            return nil
        }
        return [picked]
    }

    // MARK: 提示

    private static func alertNoVideo(in folder: URL) {
        let a = NSAlert()
        a.messageText = "这个文件夹里没有视频"
        a.informativeText = "支持的格式：\(videoExtensions.sorted().joined(separator: " / "))"
        a.alertStyle = .informational
        a.addButton(withTitle: "好")
        a.runModal()
    }

    private static func alertNotVideo(_ url: URL) {
        let a = NSAlert()
        a.messageText = "这不是视频文件"
        a.informativeText = "「\(url.lastPathComponent)」不是可识别的视频格式。\n\n"
            + "支持的格式：\(videoExtensions.sorted().joined(separator: " / "))"
        a.alertStyle = .informational
        a.addButton(withTitle: "好")
        a.runModal()
    }
}

// MARK: - 应用设置里的视频列表

extension Settings {

    /// 设置视频列表，并顺手打开壁纸。
    /// 单独抽出来是为了让菜单栏选取和拖拽走同一条路径，行为不会分叉。
    mutating func setVideos(_ urls: [URL]) {
        video.urls = urls
        video.url = nil
        isEnabled = true
    }

    mutating func clearVideos() {
        video.urls = []
        video.url = nil
    }

    /// 当前视频的文字描述
    var videoSummary: String {
        let n = video.urls.count
        if n == 0 { return "未选择视频" }
        if n == 1 { return video.urls[0].lastPathComponent }
        return "\(n) 个视频轮播" + (video.shuffle ? "（随机）" : "")
    }
}
// MARK: - 素材能力探测

import AVFoundation

enum VideoProbe {
    /// 读视频的标称帧率与分辨率。失败返回 nil。
    static func info(of url: URL) async -> (fps: Double, size: CGSize)? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        let fps = Double((try? await track.load(.nominalFrameRate)) ?? 0)
        let size = (try? await track.load(.naturalSize)) ?? .zero
        guard fps > 0.5 else { return nil }
        return (fps, size)
    }

    /// 当前屏幕刷新率上限
    static var displayMaxHz: Double {
        Double(NSScreen.main?.maximumFramesPerSecond ?? 60)
    }

    /// 在保证「逐帧不丢」的前提下，这个素材最高能用到多少倍速。
    ///
    /// 原理：解码器按 `源帧率 × 倍速` 产帧，屏幕每秒只能上屏 `刷新率` 帧。
    /// 两者相等时最顺滑；产帧多于刷新率就只能丢，丢得不均匀就会"一卡一卡"。
    static func smoothLimit(sourceFPS: Double) -> Double? {
        guard sourceFPS > 0.5 else { return nil }
        let raw = displayMaxHz / sourceFPS
        return Params.Video.speedSteps.last(where: { $0 <= raw + 0.001 })
    }
}
