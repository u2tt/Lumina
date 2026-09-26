import Foundation

// ============================================================
//  Lumina —— 纯视频动态壁纸
//
//  设计取舍：只保留视频播放，不做任何实时渲染（无 Metal / 无着色器）。
//  壁纸内容完全交给 AVFoundation，GPU 只用于视频解码，空闲时几乎零开销。
// ============================================================

// MARK: - 视频参数

enum Params {

    struct Video: Codable, Equatable {
        /// 播放列表。
        /// 1 个 = 循环播放这一个；多个 = 播完一个自动切下一个。
        /// ⚠️ 选文件夹时会一次性填入文件夹里的全部视频。
        var urls: [URL] = []

        /// 旧版本的单视频字段。加载时会被并进 `urls`，之后清空。
        /// 保留它是为了老用户的设置不丢。
        var url: URL? = nil

        var fillMode: FillMode = .fill
        var volume: Double = 0.0        // 0 ... 1（默认静音）
        var speed: Double = 1.0         // 取值见 speedSteps
        var dim: Double = 0.0           // 0 ... 0.8 压暗，让桌面图标更清楚
        /// 随机播放：每次切下一个时从列表里随机挑（不重复走完一轮）
        var shuffle: Bool = false

        /// 播放速度档位。
        /// ⚠️ 1.0 必须有 —— 没有它就没法回到正常速度。
        static let speedSteps: [Double] = [0.5, 1.0, 1.5, 2.0, 3.0, 5.0]

        /// 把任意值吸附到最近的档位（CLI 传了非档位值时用）
        static func nearestStep(_ v: Double) -> Double {
            speedSteps.min(by: { abs($0 - v) < abs($1 - v) }) ?? 1.0
        }

        /// 浮点容差：0.4 这类值编码成 JSON 再读回来会有极小误差
        static func sameStep(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.001 }

        enum FillMode: String, CaseIterable, Codable, Identifiable {
            case fill, fit, stretch
            var id: String { rawValue }
            var title: String {
                switch self {
                case .fill:    return "填充（裁切铺满）"
                case .fit:     return "适应（可能留黑边）"
                case .stretch: return "拉伸铺满"
                }
            }
        }

        /// 把旧字段并进 urls，并去掉不存在的文件
        mutating func normalize() {
            if let legacy = url {
                if !urls.contains(legacy) { urls.insert(legacy, at: 0) }
                url = nil
            }
            var seen = Set<String>()
            urls = urls.filter { seen.insert($0.path).inserted }
        }

        /// 实际能播放的文件（存在且可读）
        var availableURLs: [URL] {
            urls.filter { FileManager.default.isReadableFile(atPath: $0.path) }
        }

        /// 当前视频（列表首个；播放中会随轮播推进）
        var current: URL? { urls.first }

        var isPlaylist: Bool { urls.count > 1 }

        // 容错解码：任何一个键缺失都退回默认值，而不是让整份设置解码失败。
        // （Swift 自动合成的 Decodable 缺键会直接抛错，导致用户设置被静默清空）
        init() {}

        enum CodingKeys: String, CodingKey {
            case urls, url, fillMode, volume, speed, dim, shuffle
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Params.Video()
            urls = (try? c.decode([URL].self, forKey: .urls)) ?? d.urls
            url = try? c.decodeIfPresent(URL.self, forKey: .url)
            fillMode = (try? c.decode(FillMode.self, forKey: .fillMode)) ?? d.fillMode
            volume = (try? c.decode(Double.self, forKey: .volume)) ?? d.volume
            speed = (try? c.decode(Double.self, forKey: .speed)) ?? d.speed
            dim = (try? c.decode(Double.self, forKey: .dim)) ?? d.dim
            shuffle = (try? c.decode(Bool.self, forKey: .shuffle)) ?? d.shuffle
        }
    }
}

// MARK: - 全局设置

struct Settings: Codable, Equatable {
    var isEnabled: Bool = true
    var video = Params.Video()

    /// 暂停策略（省电）
    var pauseOnFullscreen: Bool = true
    var pauseOnBattery: Bool = false
    var pauseWhenOccluded: Bool = false

    /// 壁纸压在桌面图标之上（默认否，与系统壁纸行为一致）
    var pinAboveDesktopIcons: Bool = false

    static let storageKey = "lumina.settings.v1"

    init() {}

    enum CodingKeys: String, CodingKey {
        case isEnabled, video
        case pauseOnFullscreen, pauseOnBattery, pauseWhenOccluded
        case pinAboveDesktopIcons
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        isEnabled = (try? c.decode(Bool.self, forKey: .isEnabled)) ?? d.isEnabled
        video = (try? c.decode(Params.Video.self, forKey: .video)) ?? d.video
        pauseOnFullscreen = (try? c.decode(Bool.self, forKey: .pauseOnFullscreen)) ?? d.pauseOnFullscreen
        pauseOnBattery = (try? c.decode(Bool.self, forKey: .pauseOnBattery)) ?? d.pauseOnBattery
        pauseWhenOccluded = (try? c.decode(Bool.self, forKey: .pauseWhenOccluded)) ?? d.pauseWhenOccluded
        pinAboveDesktopIcons = (try? c.decode(Bool.self, forKey: .pinAboveDesktopIcons)) ?? d.pinAboveDesktopIcons
    }

    /// 开箱默认播放的视频（macOS 自带的 Aerial 航拍壁纸素材）。
    ///
    /// ⚠️ 只在**首次运行**（本机从未存过设置）时套用。
    /// 若每次加载都在"视频为空"时补上，就会和「清空视频」冲突 ——
    /// 用户一清空立刻又被填回来，永远回不到系统壁纸。
    /// 所以：清空是清空，默认只是起点。
    /// macOS 自带 Aerial 航拍壁纸素材所在目录。
    /// 这是系统自带的，人人都有 —— 用它当默认素材最自然。
    static var aerialVideosDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/videos",
                                    isDirectory: true)
    }

    /// 选择面板默认打开的目录：优先 Aerial 素材库，否则「影片」目录
    static var defaultVideoDirectory: URL? {
        let aerial = aerialVideosDirectory
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: aerial.path, isDirectory: &isDir), isDir.boolValue {
            return aerial
        }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
    }

    /// 取一个可用的默认视频：Aerial 素材库里第一个能读的 .mov。
    ///
    /// ⚠️ 早期版本把某个具体素材的**绝对路径**（含用户名、含 UUID）写死在源码里，
    ///    这对别的机器毫无意义。改成运行时扫描目录 —— 谁都能用。
    static var existingDefaultVideo: URL? {
        let dir = aerialVideosDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return nil }

        return items
            .filter { url in
                url.pathExtension.lowercased() == "mov"
                    && FileManager.default.isReadableFile(atPath: url.path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    /// 套用开箱默认值（仅首次运行时调用），并**立即落盘**。
    ///
    /// ⚠️ 必须落盘，否则默认值只活在内存里：
    ///   · 每次启动都会重新"首次运行"一遍
    ///   · 更要紧的是用户清空后，下次启动又被当成首次运行填回默认视频，
    ///     于是永远回不到系统壁纸
    /// 这里直接写 UserDefaults、**不发通知** —— 此刻 Controller 还没建好，
    /// 发通知会引发无谓的重入。
    private static func applyOutOfBoxDefaults(_ s: Settings) -> Settings {
        var out = s
        if out.video.urls.isEmpty, let d = existingDefaultVideo {
            out.video.urls = [d]
            Log.info("首次运行 → 默认播放 \(d.lastPathComponent)")
        }
        if let data = try? JSONEncoder().encode(out) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        return out
    }

    static func load() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return applyOutOfBoxDefaults(Settings())     // 首次运行：套用开箱默认视频
        }
        do {
            var s = try JSONDecoder().decode(Settings.self, from: data)
            s.video.normalize()
            return s
        } catch {
            // 理论上不会走到这里（上面每个字段都是容错解码），
            // 但真出问题时必须留痕，不能静默恢复默认 —— 那等于把用户设置悄悄清空。
            Log.error("设置解码失败，已回退默认值：\(error)")
            let backup = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/Lumina.settings.corrupt.json")
            try? data.write(to: backup)
            Log.error("原始设置已备份到 \(backup.path)")
            return applyOutOfBoxDefaults(Settings())
        }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Settings.storageKey)
        NotificationCenter.default.post(name: .luminaSettingsChanged, object: nil)
    }
}

extension Notification.Name {
    static let luminaSettingsChanged = Notification.Name("lumina.settings.changed")
    static let luminaToggleRequested = Notification.Name("lumina.toggle.requested")
    /// 请求切到下一幅（设置界面的按钮发出的；Controller 监听并执行）
    static let luminaNextRequested = Notification.Name("lumina.next.requested")
}

extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(hi, Swift.max(lo, self)) }
}
