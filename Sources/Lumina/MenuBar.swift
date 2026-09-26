import Cocoa

// ============================================================
//  菜单栏
//
//  只做视频壁纸：选视频 / 选文件夹 / 暂停 / 开关。
//  不放"壁纸种类"之类的二级菜单 —— 模式由视频个数决定，不需要用户选。
// ============================================================

// MARK: - 登录项（LaunchAgent）

enum LaunchAgent {
    static let label = "com.chenxinyu.lumina"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static var statusText: String {
        isInstalled ? "已写入 ~/Library/LaunchAgents/\(label).plist" : "未设置开机自启"
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            guard let exe = Bundle.main.executableURL?.path else {
                Log.error("找不到可执行文件路径，无法设置自启")
                return false
            }
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [exe, "--autostart"],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive",
                "LimitLoadToSessionType": "Aqua"
            ]
            do {
                try FileManager.default.createDirectory(
                    at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: plistURL)
            } catch {
                Log.error("写入 LaunchAgent 失败: \(error)")
                return false
            }
            // 已加载则先卸载，避免 bootstrap 报 "service already loaded"
            shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
            let r = shell("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
            Log.info("已启用开机自启 (launchctl bootstrap 退出码 \(r))")
            return true
        } else {
            shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
            try? FileManager.default.removeItem(at: plistURL)
            Log.info("已关闭开机自启")
            return true
        }
    }

    @discardableResult
    private static func shell(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}

// MARK: - 菜单栏控制器

final class MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let state: AppState
    private let controller: WallpaperController
    private let openSettings: () -> Void

    init(state: AppState, controller: WallpaperController, openSettings: @escaping () -> Void) {
        self.state = state
        self.controller = controller
        self.openSettings = openSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.toolTip = "Lumina 视频壁纸"
        buildMenu()
        updateIcon()

        Log.info("菜单初始状态:\n\(dumpMenuState())")

        // 状态栏图标坐标：排查/自动化时用来精确定位，省得靠截图猜。
        // ⚠️ init 阶段按钮还没完成布局，此时读 frame 会得到 w=38 h=0，必须等一拍。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let f = self.statusItem.button?.window?.frame else { return }
            Log.info("状态栏图标 frame: x=\(Int(f.origin.x)) y=\(Int(f.origin.y)) w=\(Int(f.width)) h=\(Int(f.height))")
        }

        // 设置变化时同步图标与文字，避免菜单停留在旧状态
        NotificationCenter.default.addObserver(forName: .luminaSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.updateIcon()
            if let m = self.statusItem.menu { self.syncStates(in: m) }
        }
    }

    // MARK: 菜单构建

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let toggle = NSMenuItem(title: "启用壁纸", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.tag = 1
        menu.addItem(toggle)

        let pause = NSMenuItem(title: "暂停播放", action: #selector(togglePause), keyEquivalent: "p")
        pause.target = self
        pause.tag = 2
        menu.addItem(pause)

        // 下一幅：手动切到播放列表的下一个
        let next = NSMenuItem(title: "下一幅", action: #selector(skipToNext), keyEquivalent: "n")
        next.target = self
        next.tag = 6
        menu.addItem(next)

        menu.addItem(.separator())

        // 放本地视频的主入口：一步到文件选择
        let pick = NSMenuItem(title: "选择视频…", action: #selector(pickVideo), keyEquivalent: "o")
        pick.target = self
        menu.addItem(pick)

        let current = NSMenuItem(title: "当前：未选择视频", action: nil, keyEquivalent: "")
        current.tag = 3
        current.isEnabled = false
        menu.addItem(current)

        // 随机播放：列表超过 1 个才有意义
        let shuffle = NSMenuItem(title: "随机播放", action: #selector(toggleShuffle), keyEquivalent: "r")
        shuffle.target = self
        shuffle.tag = 5
        menu.addItem(shuffle)

        let clear = NSMenuItem(title: "清空视频", action: #selector(clearVideos), keyEquivalent: "")
        clear.target = self
        clear.tag = 4
        menu.addItem(clear)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let log = NSMenuItem(title: "打开日志", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        let about = NSMenuItem(title: "关于 Lumina", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: 状态同步

    func syncStates(in menu: NSMenu) {
        for item in menu.items {
            switch item.tag {
            case 1:
                item.state = state.settings.isEnabled ? .on : .off
            case 2:
                item.state = controller.manualPaused ? .on : .off
                item.isEnabled = state.settings.isEnabled
            case 3:
                item.title = "当前：\(state.settings.videoSummary)"
            case 4:
                item.isEnabled = !state.settings.video.urls.isEmpty
            case 5:
                item.state = state.settings.video.shuffle ? .on : .off
                item.isEnabled = state.settings.video.urls.count > 1
            case 6:
                // 只有一个视频时"下一幅"没有意义
                item.isEnabled = state.settings.isEnabled
                    && state.settings.video.availableURLs.count > 1
            default:
                break
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        syncStates(in: menu)
    }

    /// 把菜单真实状态导成文本，供日志留痕与自检
    func dumpMenuState() -> String {
        guard let menu = statusItem.menu else { return "  (没有菜单)" }
        syncStates(in: menu)
        return menu.items
            .filter { !$0.isSeparatorItem }
            .map { item in
                let mark = item.state == .on ? "[✓]" : "[ ]"
                let extra = (item.tag >= 1 && item.tag <= 4) ? "   (可点击=\(item.isEnabled))" : ""
                return "  \(mark) \(item.title)\(extra)"
            }
            .joined(separator: "\n")
    }

    private func updateIcon() {
        let on = state.settings.isEnabled

        // ⚠️ 曾经用 "sparkles.slash" 表示关闭态，但该 SF Symbol 并不存在
        // （已用 NSImage(systemSymbolName:) 实测为 nil），结果是一旦关闭壁纸，
        // 状态栏图标直接消失，用户再也点不到菜单。
        // 现在：图标恒用确定存在的 "sparkles"，关闭时只把图标置灰。
        let img = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Lumina")
            ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Lumina")

        if let img {
            img.isTemplate = true
            statusItem.button?.image = img
            statusItem.button?.title = ""
        } else {
            statusItem.button?.image = nil          // 极端兜底，保证图标不会消失
            statusItem.button?.title = "◈"
        }
        statusItem.button?.appearsDisabled = !on
        statusItem.button?.toolTip = on ? "Lumina 视频壁纸 · 播放中" : "Lumina 视频壁纸 · 已关闭"
    }

    // MARK: 动作

    @objc private func toggleEnabled() {
        state.settings.isEnabled.toggle()
        updateIcon()
    }

    @objc private func togglePause() {
        controller.manualPaused.toggle()
    }

    @objc private func pickVideo() {
        guard let picked = VideoImporter.pickFiles() else { return }
        state.settings.setVideos(picked)
        updateIcon()
        Log.info("菜单选视频 → \(picked.map(\.lastPathComponent).joined(separator: ", "))")
    }

    @objc private func skipToNext() {
        controller.skipToNext()
    }

    @objc private func toggleShuffle() {
        state.settings.video.shuffle.toggle()
        Log.info(state.settings.video.shuffle ? "已开启随机播放" : "已关闭随机播放（按文件名顺序）")
    }

    @objc private func clearVideos() {
        state.settings.clearVideos()
        Log.info("已清空视频列表")
    }

    @objc private func showSettings() { openSettings() }

    @objc private func openLog() { NSWorkspace.shared.open(Log.logURL) }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Lumina 视频壁纸 v\(AppInfo.version)"
        alert.informativeText = """
        把本地视频当作 macOS 桌面壁纸。

        壁纸渲染在桌面层窗口上，位于系统壁纸之上、桌面图标之下，\
        不会遮挡任何应用窗口，也不响应鼠标事件。

        选定的视频循环播放。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func quit() {
        Log.info("用户从菜单栏退出")
        controller.stop()
        NSApp.terminate(nil)
    }
}
