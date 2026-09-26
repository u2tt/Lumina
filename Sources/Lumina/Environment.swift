import Cocoa
import CoreGraphics
import ApplicationServices
import IOKit
import IOKit.ps

// MARK: - 环境监测（省电：电池 / 全屏 / 遮挡 / 锁屏）

final class EnvironmentMonitor {

    private(set) var isOnBattery = false
    private(set) var isFullscreenAppActive = false
    private(set) var isScreenLocked = false
    private(set) var isScreensAsleep = false

    private var timer: Timer?
    private var batterySource: CFRunLoopSource?

    /// 状态变化回调（主线程）
    var onChange: (() -> Void)?

    func start() {
        stop()

        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        NotificationCenter.default.addObserver(self, selector: #selector(flagsChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(screenLocked), name: .init("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(screenUnlocked), name: .init("com.apple.screenIsUnlocked"), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screensSlept),
                                                          name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screensWoke),
                                                          name: NSWorkspace.screensDidWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(flagsChanged),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
        sample()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func flagsChanged() { sample() }
    @objc private func screenLocked()  { isScreenLocked = true;  onChange?() }
    @objc private func screenUnlocked() { isScreenLocked = false; onChange?() }
    @objc private func screensSlept()  { isScreensAsleep = true;  onChange?() }
    @objc private func screensWoke()   { isScreensAsleep = false; onChange?() }

    private func sample() {
        let prevBattery = isOnBattery
        let prevFull = isFullscreenAppActive
        isOnBattery = Self.readOnBattery()
        isFullscreenAppActive = Self.detectFullscreen()

        if prevBattery != isOnBattery || prevFull != isFullscreenAppActive {
            onChange?()
        }
    }

    // MARK: 电池

    private static func readOnBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let state = desc[kIOPSPowerSourceStateKey] as? String {
                return state == kIOPSBatteryPowerValue
            }
        }
        return false
    }

    // MARK: 全屏检测

    /// 用 CGWindowList 判断最前面的可见窗口是否覆盖了整个屏幕（即全屏 App）。
    /// 这是近似判断，但比 AX API 快且不需要额外权限。
    static func detectFullscreen() -> Bool {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        let screens = NSScreen.screens.map { $0.frame }
        guard !screens.isEmpty else { return false }

        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            guard let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.01 else { continue }

            // 这个窗口是否几乎完全覆盖了某块屏幕
            for screen in screens {
                let inter = screen.intersection(rect)
                if inter.isNull { continue }
                let coverage = (inter.width * inter.height) / max(screen.width * screen.height, 1)
                if coverage > 0.985 { return true }
            }
            break   // 只看最前面的一个 layer-0 窗口
        }
        return false
    }

    /// 判断壁纸窗口是否被完全遮挡（用于 pauseWhenOccluded）
    ///
    /// ⚠️ 查询**不能**带 `.excludeDesktopElements`：
    /// 壁纸窗口层级低于桌面图标，会被该选项当"桌面元素"过滤掉，
    /// 于是永远找不到壁纸窗口、遮挡检测彻底失效。
    /// （`detectFullscreen` 那边保留该选项是对的 —— 那里本就该忽略桌面层元素。）
    static func isOccluded(screenFrame: CGRect, wallpaperWindowNumber: Int) -> Bool {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        for info in infoList {
            guard let number = info[kCGWindowNumber as String] as? Int, number == wallpaperWindowNumber else { continue }
            // 排在壁纸窗口之前的窗口就是压在它上面的
            break
        }

        // 找出所有排在壁纸窗口前面的、覆盖度足够高的窗口
        var covered = false
        for info in infoList {
            guard let number = info[kCGWindowNumber as String] as? Int else { continue }
            if number == wallpaperWindowNumber { break }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 0 else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            let inter = screenFrame.intersection(rect)
            if inter.isNull { continue }
            let coverage = (inter.width * inter.height) / max(screenFrame.width * screenFrame.height, 1)
            if coverage > 0.98 { covered = true; break }
        }
        return covered
    }
}
