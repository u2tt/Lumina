import Cocoa
import SwiftUI
import Darwin

// ============================================================
//  Lumina 视频壁纸 —— 入口
// ============================================================

// MARK: - 单实例锁
//
// ⚠️ 不要只用 NSRunningApplication.runningApplications(withBundleIdentifier:) 判断单实例。
// 实测踩坑（2026-09-26）：SIGKILL 强制结束后 LaunchServices 注册表更新有延迟，
// 紧接着重启会读到"幽灵实例"（ps 里明明没有进程，却报告 count > 1），
// 新进程于是当场自杀退出，用户看到的现象是"点了图标打不开"。
//
// 改用 flock：锁随进程存活一直持有，进程一死内核立刻释放，没有延迟。
// 顺带还能防住"同时双击两次"的竞态。
private var singleInstanceLockFD: Int32 = -1

private func acquireSingleInstanceLock() -> Bool {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("com.chenxinyu.lumina.lock")
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return true }          // 建不了锁文件就不阻止启动，宁可多开也别打不开
    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
        singleInstanceLockFD = fd
        return true
    }
    close(fd)
    return false
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var state: AppState!
    private var controller: WallpaperController!
    private var menuBar: MenuBarController!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard acquireSingleInstanceLock() else {
            Log.warn("已有实例在运行（flock 被占用），本次退出")
            NSApp.terminate(nil)
            return
        }

        Log.info("=== Lumina 启动 pid=\(ProcessInfo.processInfo.processIdentifier) ===")
        Log.info("macOS \(ProcessInfo.processInfo.operatingSystemVersionString) / 屏幕数 \(NSScreen.screens.count)")

        NSApp.setActivationPolicy(.accessory)

        state = AppState()
        controller = WallpaperController(settings: state.settings)

        state.onChange = { [weak self] new, old in
            self?.controller.apply(newSettings: new, old: old)
        }
        NotificationCenter.default.addObserver(forName: .luminaToggleRequested, object: nil, queue: .main) { [weak self] _ in
            self?.state.settings.isEnabled.toggle()
        }

        controller.start()
        startClearSelfTestIfRequested()
        startNextSelfTestIfRequested()

        menuBar = MenuBarController(state: state, controller: controller) { [weak self] in
            self?.showSettings()
        }

        // 首次运行（从未存过设置）自动弹出设置，让用户知道装好了
        if UserDefaults.standard.data(forKey: Settings.storageKey) == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.showSettings()
            }
        }
    }

    /// 自测钩子：LUMINA_CLEARTEST=<秒> 时，启动后先正常播放，到点清空视频、
    /// 再等同样时长恢复。用来验证「清空 → 销毁窗口露出系统壁纸 → 重选 → 重建窗口」
    /// 这条运行时路径，不必手工点菜单。
    private func startClearSelfTestIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["LUMINA_CLEARTEST"],
              let gap = Double(raw), gap > 1 else { return }
        Log.info("清空自测：\(Int(gap))s 后清空视频，再 \(Int(gap))s 后恢复")

        DispatchQueue.main.asyncAfter(deadline: .now() + gap) { [weak self] in
            guard let self else { return }
            let before = self.state.settings.video.urls
            Log.info("清空自测：执行清空（原有 \(before.count) 个视频）")
            self.state.settings.clearVideos()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + gap * 2) { [weak self] in
            guard let self else { return }
            let list = ProcessInfo.processInfo.environment["LUMINA_CLEARTEST_RESTORE"] ?? ""
            let urls = list.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            Log.info("清空自测：恢复 \(urls.count) 个视频")
            self.state.settings.setVideos(urls)
        }
    }

    /// 自测钩子：LUMINA_NEXT_TEST=次数,间隔秒 时，按序触发「下一幅」。
    /// 刻意走**设置界面按钮的同一条路径**（发通知），确保测的就是真实链路。
    private func startNextSelfTestIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["LUMINA_NEXT_TEST"] else { return }
        let parts = raw.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        guard let count = parts.first.map({ Int($0) }), count > 0 else { return }
        let gap = parts.count > 1 ? parts[1] : 2.5
        Log.info("下一幅自测：\(count) 次，间隔 \(gap)s")

        for i in 1...count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0 + Double(i) * gap) {
                Log.info("下一幅自测：第 \(i) 次触发")
                NotificationCenter.default.post(name: .luminaNextRequested, object: nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
        Log.info("=== Lumina 退出 ===")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func showSettings() {
        NSApp.activate(ignoringOtherApps: true)

        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(state: state))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Lumina 视频壁纸 — 设置"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 760, height: 580))
            w.minSize = NSSize(width: 700, height: 480)
            w.center()
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 命令行

private let args = CommandLine.arguments

private func argValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

private func speedText(_ s: Double) -> String {
    let f = s == s.rounded() ? String(format: "%.0f", s) : String(format: "%.1f", s)
    return "\(f)×"
}

/// 收集 `--video` 后面所有连续的非选项参数
private func collectFiles(after flag: String) -> [String] {
    var out: [String] = []
    var i = 0
    while i < args.count {
        if args[i] == flag {
            var j = i + 1
            while j < args.count && !args[j].hasPrefix("--") {
                out.append(args[j]); j += 1
            }
            i = j
        } else {
            i += 1
        }
    }
    return out
}

if args.contains("--help") || args.contains("-h") {
    print("""
    Lumina 视频壁纸 —— 把本地视频当作 macOS 桌面壁纸

    用法:
      Lumina                            启动（常驻菜单栏）
      Lumina --video <路径…>            视频文件，或包含视频的文件夹
                                        （多个 / 目录 → 播完自动切下一个）
      Lumina --shuffle                  随机播放（每次随机挑下一个）
      Lumina --fill <模式>              画面填充：fill | fit | stretch
      Lumina --volume <0-1>             音量（默认 0，静音）
      Lumina --speed <倍率>             播放速度，档位：0.5 1 1.5 2 3 5
      Lumina --dim <0-0.8>              压暗视频，让桌面图标更清楚

      Lumina --reset                    清除全部设置后退出（不启动）
      Lumina --dump                     打印当前设置的实际值后退出
      Lumina --version                  显示版本

    示例:
      Lumina --video ~/Movies/video.mp4
      Lumina --video ~/Movies/我的壁纸/     # 整个文件夹轮播
      Lumina --video ~/Movies --shuffle     # 随机播放

    设置与日志:
      ~/Library/Logs/Lumina.log
    """)
    exit(0)
}

if args.contains("--version") {
    print("Lumina \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
    exit(0)
}

if args.contains("--dump") {
    // 诊断用：打印应用"实际认为"的设置值。
    // 界面显示和实际值不一致时，用它对照，比截图猜快得多。
    let s = Settings.load()
    let v = s.video
    let missing = v.urls.filter { !FileManager.default.isReadableFile(atPath: $0.path) }
    print("""
    ── 通用 ──
    壁纸启用          : \(s.isEnabled ? "开启" : "关闭")
    全屏应用时暂停    : \(s.pauseOnFullscreen ? "开" : "关")
    使用电池时暂停    : \(s.pauseOnBattery ? "开" : "关")
    被窗口遮挡时暂停  : \(s.pauseWhenOccluded ? "开" : "关")
    壁纸盖住桌面图标  : \(s.pinAboveDesktopIcons ? "是" : "否")
    ── 视频 ──
    当前视频          : \(v.urls.first?.lastPathComponent ?? "未选择视频")
    画面填充          : \(v.fillMode.title)
    音量 / 压暗       : \(Int(v.volume * 100))% / \(Int(v.dim * 100))%
    播放速度          : \(speedText(v.speed))（档位 \(Params.Video.speedSteps.map { speedText($0) }.joined(separator: " "))）
    播放顺序          : \(v.urls.count > 1 ? (v.shuffle ? "随机" : "按文件名") : "（单个视频）")
    视频列表          :
    \(v.urls.isEmpty ? "      （空）" : v.urls.map { "      \(FileManager.default.isReadableFile(atPath: $0.path) ? "✓" : "✗ 已失效") \($0.path)" }.joined(separator: "\n"))
    \(missing.isEmpty ? "" : "    ⚠️ 有 \(missing.count) 个文件已失效，壁纸会显示提示而不是黑屏")
    """)
    exit(0)
}

if args.contains("--reset") {
    UserDefaults.standard.removeObject(forKey: Settings.storageKey)
    UserDefaults.standard.synchronize()
    print("已清除 Lumina 设置")
    exit(0)
}

// ---- CLI 覆盖设置 ----
var cli = Settings.load()
var touched = false

func applyVideos(_ urls: [URL]) {
    // 参数可以是文件，也可以是目录 —— 目录展开成里面的全部视频
    var expanded: [URL] = []
    for u in urls {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
            let found = VideoImporter.videos(in: u)
            if found.isEmpty {
                FileHandle.standardError.write("警告：目录里没有视频 → \(u.path)\n".data(using: .utf8)!)
            } else {
                print("目录 \(u.lastPathComponent) → \(found.count) 个视频")
                expanded.append(contentsOf: found)
            }
        } else {
            expanded.append(u)
        }
    }

    let existing = expanded.filter { FileManager.default.isReadableFile(atPath: $0.path) }
    for bad in expanded where !existing.contains(bad) {
        FileHandle.standardError.write("警告：文件不可读 → \(bad.path)\n".data(using: .utf8)!)
    }
    guard !existing.isEmpty else {
        FileHandle.standardError.write("错误：没有可用的视频\n".data(using: .utf8)!)
        exit(2)
    }

    // 去重但保序
    var seen = Set<String>()
    let unique = existing.filter { seen.insert($0.path).inserted }

    if unique.count == 1 {
        print("视频壁纸 → \(unique[0].lastPathComponent)")
    } else {
        print("播放列表 → \(unique.count) 个视频，播完自动切下一个")
    }
    cli.setVideos(unique)
    touched = true
}

let videoArgs = collectFiles(after: "--video").map {
    URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
}
if !videoArgs.isEmpty { applyVideos(videoArgs) }


if let v = argValue("--fill"), let m = Params.Video.FillMode(rawValue: v) { cli.video.fillMode = m; touched = true }
if let v = argValue("--volume"), let d = Double(v) { cli.video.volume = d.clamped(0, 1); touched = true }
if let v = argValue("--speed"),  let d = Double(v) {
    // 速度是固定档位，传进来的值吸附到最近的一档
    let snapped = Params.Video.nearestStep(d)
    if !Params.Video.sameStep(snapped, d) {
        print("播放速度 \(d) 不在档位内，已吸附到 \(speedText(snapped))")
    }
    cli.video.speed = snapped
    touched = true
}
if let v = argValue("--dim"),    let d = Double(v) { cli.video.dim = d.clamped(0, 0.8); touched = true }
if args.contains("--shuffle") { cli.video.shuffle = true; touched = true }

if touched { cli.save() }

// MARK: 启动

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
