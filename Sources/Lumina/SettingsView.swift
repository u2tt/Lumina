import SwiftUI
import UniformTypeIdentifiers

// ============================================================
//  设置界面
//
//  字号阶梯固定 5 级：20 / 16 / 13 / 12 / 11，不出现阶梯外的字号。
//  单一强调色，靠留白分组，不堆装饰。
// ============================================================

// MARK: - 字号阶梯（集中管理）

/// 界面字号统一定义在这里。想整体调大/调小只改 `delta` 一个数。
///
/// 当前比原始设计大两号（用户要求）。
/// 阶梯固定 6 级，不出现阶梯外的字号：pageTitle / sectionTitle / label / body / caption / iconBig
enum FontSize {
    /// 整体增量（"大两号"）
    static let delta: CGFloat = 2

    static let caption: CGFloat = 11 + delta    // 说明、次要信息
    static let body: CGFloat = 12 + delta       // 控件标签、列表项
    static let sectionTitle: CGFloat = 13 + delta
    static let pageTitle: CGFloat = 20 + delta
    static let iconBig: CGFloat = 26 + delta
}

// MARK: - 基础控件

struct SectionBox<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: FontSize.sectionTitle, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.system(size: FontSize.caption)).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
    }
}

struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: String = "%.2f"
    var unit: String = ""
    /// 显示倍率。百分比场景传 100 ——
    /// 否则 `String(format: "%.0f%%", 0.85)` 会显示成 "1%"（真实踩过的坑）。
    var displayScale: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: FontSize.body))
                Spacer()
                Text(String(format: format, value * displayScale) + unit)
                    .font(.system(size: FontSize.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range).controlSize(.small)
        }
    }
}

// MARK: - 页面

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, video
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .video:   return "视频壁纸"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .video:   return "film"
        }
    }
    var subtitle: String {
        switch self {
        case .general: return "开机自启、省电与显示设置"
        case .video:   return "选择视频或文件夹；多个视频会依次轮播"
        }
    }
}

// MARK: - 主界面

struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var page: SettingsPage = .video
    @State private var isDropping = false

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $page) { p in
                Label(p.title, systemImage: p.symbol).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 165, max: 200)
            .listStyle(.sidebar)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    switch page {
                    case .general: GeneralPage(state: state)
                    case .video:   VideoPage(state: state)
                    }
                }
                .padding(18)
                .frame(maxWidth: 620, alignment: .leading)
            }
            .frame(minWidth: 480, minHeight: 420)
        }
        .frame(width: 760, height: 580)
        // 直接把视频文件拖进来就设为壁纸 —— 比"设置→选择文件"少好几步
        .onDrop(of: [.fileURL], isTargeted: $isDropping) { handleDrop($0) }
        .overlay {
            if isDropping {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.10))
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    VStack(spacing: 6) {
                        Image(systemName: "film.stack").font(.system(size: FontSize.iconBig))
                        Text("松开即设为壁纸").font(.system(size: FontSize.sectionTitle, weight: .medium))
                        Text("松开即设为壁纸，循环播放").font(.system(size: FontSize.caption)).foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
                }
                .padding(8)
                .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(page.title).font(.system(size: FontSize.pageTitle, weight: .semibold))
                Text(page.subtitle).font(.system(size: FontSize.caption)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("启用", isOn: $state.settings.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    // MARK: 拖拽接收

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let candidates = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !candidates.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for p in candidates {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let u = item as? URL {
                    url = u
                } else if let d = item as? Data {
                    url = URL(dataRepresentation: d, relativeTo: nil)
                }
                guard let u = url else { return }

                // 文件和文件夹都接受：
                //   文件   → 本身要是视频
                //   文件夹 → 取里面的视频（排序后第一个）
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { return }

                if isDir.boolValue {
                    let found = VideoImporter.videos(in: u)
                    guard let first = found.first else {
                        Log.warn("拖入的文件夹里没有视频：\(u.lastPathComponent)")
                        return
                    }
                    if found.count > 1 {
                        Log.info("拖入的文件夹有 \(found.count) 个视频，采用第一个：\(first.lastPathComponent)")
                    }
                    lock.lock(); urls.append(first); lock.unlock()
                    return
                }

                guard VideoImporter.isVideo(u),
                      FileManager.default.isReadableFile(atPath: u.path) else { return }
                lock.lock(); urls.append(u); lock.unlock()
            }
        }

        group.notify(queue: .main) {
            guard !urls.isEmpty else {
                Log.warn("拖入的内容里没有可用的视频")
                return
            }
            // 单视频模式：拖入多个只取第一个
            let first = urls.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }[0]
            if urls.count > 1 {
                Log.info("拖入了 \(urls.count) 个视频，只采用第一个：\(first.lastPathComponent)")
            }
            state.settings.setVideos([first])
            page = .video
            Log.info("拖入 → \(first.lastPathComponent)")
        }
        return true
    }
}

// MARK: - 通用页

struct GeneralPage: View {
    @ObservedObject var state: AppState
    @State private var launchAtLogin: Bool = LaunchAgent.isInstalled
    @State private var launchStatus: String = LaunchAgent.statusText

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionBox(title: "启动", subtitle: "登录时自动开始播放壁纸") {
                // 用 @State 承载：LaunchAgent 是文件系统状态，不是 @Published，
                // 直接读它当 Binding 的 get 会导致 SwiftUI 不重绘、开关点了弹回原样。
                Toggle("登录时自动启动", isOn: Binding(
                    get: { launchAtLogin },
                    set: { want in
                        LaunchAgent.setEnabled(want)
                        launchAtLogin = LaunchAgent.isInstalled   // 以磁盘实际结果为准
                        launchStatus = LaunchAgent.statusText
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                Text(launchStatus).font(.system(size: FontSize.caption)).foregroundStyle(.secondary)
            }

            SectionBox(title: "自动暂停", subtitle: "满足条件时停止播放，省电且不打扰") {
                Toggle("全屏应用时暂停", isOn: $state.settings.pauseOnFullscreen)
                Toggle("使用电池时暂停", isOn: $state.settings.pauseOnBattery)
                Toggle("被窗口完全遮挡时暂停", isOn: $state.settings.pauseWhenOccluded)
                Text("锁屏和屏幕休眠时无论如何都会暂停")
                    .font(.system(size: FontSize.caption)).foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            SectionBox(title: "桌面图标", subtitle: "决定壁纸与桌面图标的上下关系") {
                Toggle("壁纸盖住桌面图标", isOn: $state.settings.pinAboveDesktopIcons)
                    .toggleStyle(.switch).controlSize(.small)
                Text(state.settings.pinAboveDesktopIcons
                     ? "壁纸永远可见，桌面图标会被挡住。不受影响的是：你打开的应用窗口仍显示在壁纸之上。"
                     : "桌面图标显示在壁纸之上（与系统壁纸行为一致，推荐）。")
                    .font(.system(size: FontSize.caption)).foregroundStyle(.secondary)
                if state.settings.pinAboveDesktopIcons {
                    Label("桌面图标被挡住了，关掉这个开关即可恢复",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: FontSize.caption))
                        .foregroundStyle(.orange)
                }
            }

            SectionBox(title: "关于") {
                HStack {
                    Text("Lumina 视频壁纸").font(.system(size: FontSize.body, weight: .medium))
                    Spacer()
                    Text("v\(AppInfo.version)").font(.system(size: FontSize.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Button("打开日志") { NSWorkspace.shared.open(Log.logURL) }
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - 视频页

struct VideoPage: View {
    @ObservedObject var state: AppState
    @State private var sourceFPS: Double = 0

    private var videos: [URL] { state.settings.video.urls }
    private var available: Int { state.settings.video.availableURLs.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            SectionBox(title: "视频源", subtitle: "支持 mp4 / mov / m4v / mkv 等，建议 H.264 或 HEVC") {
                HStack(spacing: 8) {
                    Button("选择视频…") { pickFiles() }.controlSize(.small)
                    Button("下一幅") {
                        NotificationCenter.default.post(name: .luminaNextRequested, object: nil)
                    }
                    .controlSize(.small)
                    .disabled(state.settings.video.availableURLs.count <= 1)
                    .help("立刻切到播放列表的下一个视频")
                    Spacer()
                    Button("清空") { state.settings.clearVideos() }
                        .controlSize(.small)
                        .disabled(videos.isEmpty)
                }

                // 消除误解：有人以为"选择文件"会把视频导入成一份副本
                Label("只记录文件路径，不会复制或移动你的原文件", systemImage: "link")
                    .font(.system(size: FontSize.caption))
                    .foregroundStyle(.secondary)

                if videos.isEmpty {
                    Text("还没有选择视频。也可以直接把视频文件或文件夹拖到这个窗口。")
                        .font(.system(size: FontSize.caption)).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Text("共 \(videos.count) 个")
                            .font(.system(size: FontSize.body, weight: .medium))
                        Text(videos.count > 1 ? "· 播完自动切下一个" : "· 循环播放")
                            .font(.system(size: FontSize.caption)).foregroundStyle(.secondary)
                        Spacer()
                        if available < videos.count {
                            Label("\(videos.count - available) 个已失效", systemImage: "exclamationmark.triangle")
                                .font(.system(size: FontSize.caption))
                                .foregroundStyle(.orange)
                        }
                    }
                    if videos.count > 1 {
                        Toggle("随机播放（每次随机挑下一个）", isOn: $state.settings.video.shuffle)
                            .toggleStyle(.switch).controlSize(.small)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(videos.enumerated()), id: \.offset) { idx, url in
                            videoRow(index: idx, url: url)
                        }
                    }
                }
            }

            SectionBox(title: "播放") {
                Picker("画面填充", selection: $state.settings.video.fillMode) {
                    ForEach(Params.Video.FillMode.allCases) { m in Text(m.title).tag(m) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 300)

                // 速度用固定档位而不是连续滑块：
                // 连续滑块很难拖准，而且常用倍率就那么几档
                HStack {
                    Text("播放速度").font(.system(size: FontSize.body))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { Params.Video.nearestStep(state.settings.video.speed) },
                        set: { state.settings.video.speed = $0 }
                    )) {
                        ForEach(Params.Video.speedSteps, id: \.self) { s in
                            Text(Self.speedLabel(s)).tag(s)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 100)
                }
                // 高倍速是否发卡，取决于「源帧率 × 倍速」有没有超过屏幕刷新率。
                // 把这个上限直接标出来，省得靠试。
                if let limit = VideoProbe.smoothLimit(sourceFPS: sourceFPS) {
                    let over = state.settings.video.speed > limit + 0.001
                    Text(over
                         ? String(format: "本素材 %.0ffps × %.1f× 需要 %.0f 帧/秒，屏幕每秒只能显示 %.0f 帧。"
                                          + "多出的部分无法呈现，但播放是顺的 —— 程序会自动限制解码输出，避免解码器过载崩掉。",
                                  sourceFPS, state.settings.video.speed,
                                  sourceFPS * state.settings.video.speed, VideoProbe.displayMaxHz)
                         : String(format: "本素材 %.0ffps，屏幕 %.0fHz → 当前倍速可逐帧无损播放",
                                  sourceFPS, VideoProbe.displayMaxHz))
                        .font(.system(size: FontSize.caption))
                        .foregroundStyle(.secondary)
                }
                if state.settings.video.speed > 2.0 {
                    // AVPlayer 对 >2× 有硬限制，实测某些素材 2.2× 就停摆。
                    // 这里说明程序已经把倍速烘焙进时间轴，不是简单设 rate。
                    Text("2× 以上会把倍速烘焙进时间轴（播放器本身跑 1×），"
                         + "以绕开 AVPlayer 的 2× 上限 —— 某些素材直接设高倍速会完全停住。")
                        .font(.system(size: FontSize.caption))
                        .foregroundStyle(.secondary)
                }
                SliderRow(label: "音量", value: $state.settings.video.volume, range: 0...1,
                          format: "%.0f%%", unit: "", displayScale: 100)
                SliderRow(label: "压暗（让桌面图标更清楚）", value: $state.settings.video.dim,
                          range: 0...0.8, format: "%.0f%%", unit: "", displayScale: 100)
            }

            // 探测素材帧率（取列表第一个作为代表）
            .task(id: videos.first) {
                guard let first = videos.first,
                      let info = await VideoProbe.info(of: first) else {
                    sourceFPS = 0
                    return
                }
                sourceFPS = info.fps
            }

        }
    }

    private static func speedLabel(_ s: Double) -> String {
        let f = s == s.rounded() ? String(format: "%.0f", s) : String(format: "%.1f", s)
        return "\(f)×"
    }

    private func videoRow(index: Int, url: URL) -> some View {
        let exists = FileManager.default.isReadableFile(atPath: url.path)
        return HStack(spacing: 6) {
            Text("\(index + 1).")
                .font(.system(size: FontSize.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
            Image(systemName: exists ? "film" : "exclamationmark.triangle.fill")
                .font(.system(size: FontSize.caption))
                .foregroundStyle(exists ? Color.secondary : Color.orange)
            Text(url.lastPathComponent)
                .font(.system(size: FontSize.caption))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(exists ? Color.primary : Color.secondary)
            Spacer(minLength: 8)
            Button {
                var v = state.settings.video
                v.urls.remove(at: index)
                state.settings.video = v
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("从列表移除")
        }
    }

    private func pickFiles() {
        guard let picked = VideoImporter.pickFiles() else { return }
        state.settings.setVideos(picked)
    }

}

// MARK: - 信息

enum AppInfo {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }
}
