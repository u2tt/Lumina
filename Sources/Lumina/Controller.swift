import Cocoa
import SwiftUI
import Combine

// MARK: - 应用状态（SwiftUI 与 AppKit 的桥）

final class AppState: ObservableObject {
    @Published var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            // ⚠️ 顺序很重要：必须先让 controller 更新自己的 settings，再 save()。
            //    save() 会同步 post .luminaSettingsChanged（菜单栏靠它刷新图标），
            //    Controller 也监听该通知并在里面比对 Settings.load() != self.settings。
            //    若先 save()，通知回调时 controller.settings 还是旧值，
            //    会被判成"又有变化"→ 再 apply 一次 → 窗口/播放器白重建两次（会闪）。
            onChange?(settings, oldValue)
            settings.save()
        }
    }

    /// (新设置, 旧设置)
    var onChange: ((Settings, Settings) -> Void)?

    init() {
        settings = Settings.load()
    }
}

// MARK: - 壁纸窗口

final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}

// MARK: - 单屏壁纸

final class ScreenWallpaper {
    let screen: NSScreen
    let window: WallpaperWindow
    private(set) var content: VideoWallpaperView

    init(screen: NSScreen, settings: Settings) {
        self.screen = screen
        let w = WallpaperWindow(contentRect: screen.frame, styleMask: [.borderless],
                                backing: .buffered, defer: false)
        w.isOpaque = true
        w.backgroundColor = .black
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isMovable = false
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        w.level = Self.level(for: settings)
        w.setFrame(screen.frame, display: false)
        self.window = w
        self.content = VideoWallpaperView()
        content.frame = CGRect(origin: .zero, size: screen.frame.size)
        content.autoresizingMask = [.width, .height]
        w.contentView = content
    }

    /// 壁纸窗口的层级。
    ///
    /// ★ 关键事实（2026-09-27 用像素级实测重新确认）：
    ///
    ///   系统壁纸       -2147483624（owner=程序坞，第三方进程不可用同层）
    ///   桌面图标       -2147483603（owner=访达，覆盖整个屏幕）
    ///   通知中心小组件  -2147483601
    ///   普通窗口         0
    ///
    /// 之前这里写「-2147483625…-2147483602 会被 WindowServer 静默丢弃」——**那是错的**。
    /// 误判来源：自检用 `CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements])`
    /// 查询，而 `.excludeDesktopElements` 恰好会把低层级窗口当"桌面元素"**过滤掉**，
    /// 于是查不到 → 我误读成"被系统丢弃" → 挑了个 **高于桌面图标** 的 -2147483600，
    /// 结果壁纸把桌面图标整个盖住了。
    ///
    /// 全屏低层级窗口的像素实测（同一块未被遮挡区域）：
    ///   -2147483624 → 亮绿 14.8%  ✓ 正常显示
    ///   -2147483604 → 亮绿 14.8%  ✓ 正常显示
    ///   -2147483600 → 亮绿 18.4%  ✓ 正常显示（但盖住图标）
    ///
    /// 所以正确取值是 **-2147483610**：低于桌面图标（-2147483603）留出 7 层余量，
    /// 桌面图标因此显示在壁纸之上；同时远高于普通窗口，不会遮挡任何应用。
    static let baseWallpaperLevel: Int = -2147483610

    /// 壁纸压在桌面图标之上时用的层级。
    /// ⚠️ 只能用 -2147483600 这一档，绝不能像以前那样用 1 ——
    /// layer 1 高于所有普通窗口（layer 0），会把用户打开的窗口全部盖住。
    static let aboveIconLevel: Int = -2147483600

    /// 自检失败时的兜底层级（低于图标，保证图标可用）
    static let safeFallbackLevel: Int = -2147483610

    static func level(for settings: Settings) -> NSWindow.Level {
        // 默认压在桌面图标之下（与系统壁纸行为一致，图标正常可见）；
        // 开启"盖住桌面图标"时抬到 -2147483600，仍然低于普通应用窗口，
        // 所以无论开关如何，都不会遮挡用户打开的窗口。
        NSWindow.Level(rawValue: settings.pinAboveDesktopIcons ? aboveIconLevel : baseWallpaperLevel)
    }

    func show() { window.orderFrontRegardless() }
    func hide() { window.orderOut(nil) }
    func close() { window.orderOut(nil) }

    /// 自检：窗口是否真的出现在屏幕上。
    ///
    /// ⚠️ 查询**不能**带 `.excludeDesktopElements` —— 那个选项会把低层级窗口
    /// 当"桌面元素"过滤掉，导致明明正常显示的壁纸被判为"未接纳"，
    /// 进而错误地回退层级（这正是上次壁纸盖住桌面图标的起因）。
    /// 改为用 `.optionAll` 全量查询，并按窗口号比对、同时确认 onscreen。
    func verifyRegistered() -> Bool {
        guard window.isVisible, window.windowNumber > 0 else { return false }
        guard let list = CGWindowListCopyWindowInfo([.optionAll],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let num = window.windowNumber
        return list.contains { ($0[kCGWindowNumber as String] as? Int) == num }
    }

    func updateFrame() {
        window.setFrame(screen.frame, display: false)
        content.frame = CGRect(origin: .zero, size: screen.frame.size)
    }
}

// MARK: - 总控制器

final class WallpaperController {

    private(set) var settings: Settings
    private var walls: [ScreenWallpaper] = []
    private let env = EnvironmentMonitor()
    private var rebuildWork: DispatchWorkItem?
    private var lastPauseState = false

    /// 手动切到下一个视频（菜单栏「下一幅」/ 设置界面按钮）
    func skipToNext() {
        guard settings.isEnabled else {
            Log.info("壁纸未启用，「下一幅」忽略")
            return
        }
        guard !walls.isEmpty else {
            Log.info("没有壁纸窗口，「下一幅」忽略")
            return
        }
        for w in walls { w.content.skipToNext() }
    }

    /// 当前播放列表数量（供界面判断按钮是否可用）
    var playlistCount: Int { settings.video.availableURLs.count }

    /// 用户在菜单栏手动暂停
    var manualPaused: Bool = false {
        didSet {
            guard manualPaused != oldValue else { return }
            Log.info(manualPaused ? "用户手动暂停" : "用户手动恢复")
            evaluatePause()
        }
    }

    init(settings: Settings) {
        self.settings = settings
    }

    /// 是否指定了视频（不管文件还在不在）。
    /// 用来区分两种"没画面"：
    ///   · 从未选 / 主动清空 → 完全不该有壁纸窗口，直接露出系统壁纸
    ///   · 选了但文件丢了   → 保留窗口显示提示，否则用户不知道发生了什么
    private static func hasConfiguredVideo(_ s: Settings) -> Bool {
        !s.video.urls.isEmpty
    }

    private static func hasPlayableVideo(_ s: Settings) -> Bool {
        s.video.availableURLs.first != nil
    }

    /// 该不该有壁纸窗口：启用 **且** 配置了视频。
    ///
    /// ⚠️ 清空视频后必须销毁窗口 —— 否则会留一个黑底窗口盖住系统壁纸，
    ///    用户看到的就是"清空后黑屏"。让系统壁纸重新露出来才是对的。
    ///
    /// 注意这里用 hasConfiguredVideo 而不是 hasPlayableVideo：
    /// 文件被删的情况下仍要保留窗口，好让内容视图显示"文件找不到了"的提示，
    /// 否则用户只会看到壁纸莫名消失、毫无线索。
    private static func wantsWindow(_ s: Settings) -> Bool {
        s.isEnabled && hasConfiguredVideo(s)
    }

    func start() {
        env.onChange = { [weak self] in self?.evaluatePause() }
        env.start()

        NotificationCenter.default.addObserver(self, selector: #selector(screenParamsChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: .luminaSettingsChanged, object: nil)
        // 设置界面的「下一幅」按钮通过通知请求（SwiftUI 层拿不到 Controller）
        NotificationCenter.default.addObserver(self, selector: #selector(nextRequested),
                                               name: .luminaNextRequested, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceChanged),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceChanged),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)

        build()
    }

    // MARK: 构建

    private func build() {
        for w in walls { w.close() }
        walls.removeAll()

        guard settings.isEnabled else {
            Log.info("壁纸已关闭 → 不创建窗口，显示系统壁纸")
            return
        }

        // 从未选视频 / 主动清空 → 不该有壁纸窗口，让系统壁纸露出来
        guard Self.hasConfiguredVideo(settings) else {
            Log.info("未指定视频 → 不创建窗口，显示系统壁纸")
            return
        }

        if !Self.hasPlayableVideo(settings) {
            Log.warn("已指定的视频文件都不可读 → 保留窗口以显示提示")
        }

        for screen in NSScreen.screens {
            let w = ScreenWallpaper(screen: screen, settings: settings)
            w.content.apply(settings)
            w.show()
            walls.append(w)

            // 延迟自检：WindowServer 需要一两帧才会把窗口登记进列表
            let win = w.window
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.walls.contains(where: { $0.window === win }) else { return }
                if w.verifyRegistered() {
                    Log.info("自检通过：窗口 num=\(win.windowNumber) level=\(win.level.rawValue) 已被 WindowServer 接纳")
                } else {
                    Log.error("""
                    壁纸窗口未被 WindowServer 接纳！level=\(win.level.rawValue) num=\(win.windowNumber)
                    → 这是 macOS 对桌面层窗口的限制，已自动回退到安全层级 \(ScreenWallpaper.safeFallbackLevel)
                    """)
                    win.level = NSWindow.Level(rawValue: ScreenWallpaper.safeFallbackLevel)
                    win.orderFrontRegardless()
                }
            }
        }
        Log.info("已创建 \(walls.count) 个壁纸窗口")
        evaluatePause()
    }

    // MARK: 设置变更

    func apply(newSettings: Settings, old: Settings) {
        let enabledChanged = newSettings.isEnabled != old.isEnabled
        let levelChanged = newSettings.pinAboveDesktopIcons != old.pinAboveDesktopIcons
        let videoChanged = newSettings.video != old.video

        settings = newSettings

        // 开关壁纸直接重建：关掉时把 window / player 全部释放，不留解码器占用
        if enabledChanged {
            build()
            return
        }
        guard settings.isEnabled else { return }

        // ⚠️ 「该不该有窗口」发生变化时必须重建。
        //    最典型的就是用户点了「清空视频」：视频列表从非空变空，
        //    wantsWindow 由 true 变 false —— 这时要把窗口销毁掉露出系统壁纸，
        //    否则会留下一个黑底窗口，表现就是"清空后黑屏"。
        let wantsNow = Self.wantsWindow(newSettings)
        let wantedBefore = Self.wantsWindow(old)
        if wantsNow != wantedBefore {
            Log.info(wantsNow ? "已有视频 → 创建壁纸窗口" : "视频已清空 → 销毁壁纸窗口，显示系统壁纸")
            build()
            return
        }
        guard wantsNow else { return }

        guard !walls.isEmpty else {
            build()
            return
        }

        for w in walls {
            if levelChanged { w.window.level = ScreenWallpaper.level(for: settings) }
            // 只有视频配置变了才需要动 player；
            // VideoWallpaperView 内部还会再比对一次签名，避免无谓重建导致闪黑
            if videoChanged || levelChanged { w.content.apply(settings) }
            if !w.window.isVisible { w.show() }
        }
        evaluatePause()
    }

    // MARK: 暂停策略

    func evaluatePause() {
        guard settings.isEnabled else { return }
        var reasons: [String] = []

        if manualPaused { reasons.append("手动暂停") }
        if env.isScreenLocked { reasons.append("锁屏") }
        if env.isScreensAsleep { reasons.append("屏幕休眠") }
        if settings.pauseOnFullscreen && env.isFullscreenAppActive { reasons.append("全屏应用") }
        if settings.pauseOnBattery && env.isOnBattery { reasons.append("电池供电") }

        if settings.pauseWhenOccluded {
            for w in walls where w.window.isVisible {
                if EnvironmentMonitor.isOccluded(screenFrame: w.screen.frame,
                                                 wallpaperWindowNumber: w.window.windowNumber) {
                    reasons.append("被遮挡")
                    break
                }
            }
        }

        let shouldPause = !reasons.isEmpty
        if shouldPause != lastPauseState {
            lastPauseState = shouldPause
            Log.info(shouldPause ? "⏸ 暂停播放（\(reasons.joined(separator: " / "))）" : "▶️ 恢复播放")
        }
        for w in walls { w.content.setPaused(shouldPause) }
    }

    // MARK: 事件

    @objc private func screenParamsChanged() {
        // 屏幕参数变化会连续触发多次，做个防抖
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Log.info("屏幕参数变化 → 重建壁纸窗口")
            self.build()
        }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    @objc private func nextRequested() {
        skipToNext()
    }

    @objc private func settingsChanged() {
        let latest = Settings.load()
        guard latest != settings else { return }
        apply(newSettings: latest, old: settings)
    }

    @objc private func workspaceChanged() {
        // 切换 Space / App 激活后，确保壁纸窗口仍在正确的 Space 上
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            for w in self.walls where self.settings.isEnabled {
                if !w.window.isVisible { w.show() }
            }
            self.evaluatePause()
        }
    }

    func stop() {
        for w in walls { w.close() }
        walls.removeAll()
        env.stop()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
