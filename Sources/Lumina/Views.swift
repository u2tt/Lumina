import Cocoa
import AVFoundation
import QuartzCore

// ============================================================
//  视频壁纸视图（单视频循环）
//
//  ⚠️ 改这块前先读以下踩过的坑：
//
//  1) `AVPlayer.play()` 等价于 `rate = 1.0`！
//     所以「先设 rate 再 play()」会把速度重置回 1×。
//     按倍速播放必须用 `playImmediately(atRate:)`。
//
//  2) AVPlayer 对 > 2× 有硬上限。实测某个 4K 10-bit HEVC 素材：
//     2.0× 稳定 120 帧/秒，2.2× 直接掉到 0~1 帧/秒。
//     解法是把倍速**烘焙进时间轴**（scaleTimeRange），播放器只跑 1×。
//
//  3) 烘焙后改倍速必须重建内容，但**不能让画面变黑**。
//     `replaceCurrentItem` 会清空该图层的窗口缓冲，用户看到"切速度时黑一下"。
//     试过但都不够好的方案：
//       · 先拆旧层再建新层 —— 中间必然有一段黑
//       · 给旧层拍快照遮挡 —— AVPlayerLayer.contents 恒为空（播放器不走该通道）
//       · 复用同一个 player 只换 item —— replaceCurrentItem 本身就会清空缓冲
//     ✅ 正解是**双缓冲**：常备两个 (AVPlayer, AVPlayerLayer)，
//        切换时在**不可见的那个**上换 item、seek、起播，
//        等它真正出帧（isReadyForDisplay 且时间轴在走）后再交换可见性。
//        整个过程旧层一直显示着画面，屏幕无空档。
//
//  4) 重建前要记下当前进度，重建后按比例换算回去（见 load 里的 resumeAt），
//     否则改速度会从头开始。换算比例就是倍速：时间轴被压缩了 1/倍速。
//
//  5) 不要用 AVPlayerLooper（配烘焙过的 composition 帧输出会归零），
//     改成监听播放结束事件后 seek 回 0。
//
//  6) 不要给播放项挂 videoComposition 做"帧率治理" ——
//     它会打乱已烘焙的时间轴。
// ============================================================

/// 壁纸内容视图的统一接口
protocol WallpaperContentView: NSView {
    func apply(_ settings: Settings)
    func setPaused(_ paused: Bool)
    /// 立刻切到播放列表的下一个（"下一幅"按钮）。
    /// 列表只有一个时是 no-op。
    func skipToNext()
}

final class VideoWallpaperView: NSView, WallpaperContentView {

    /// 一个独立的播放通道（player + 对应图层）。双缓冲就是备两个，轮换使用。
    private final class Slot {
        let player = AVPlayer()
        let layer = AVPlayerLayer()
        /// 该槽位**当前 item** 实际烘焙所用的倍速（1.0 = 未烘焙）。
        /// ⚠️ 进度换算必须用它，不能用 videoSettings.speed ——
        /// 后者是"用户想要的值"，时间轴没重建时二者不一致，会算出假象。
        var bakedSpeed: Double = 1.0
        var url: URL?
        var tokens: [NSObjectProtocol] = []

        init() {
            player.actionAtItemEnd = .none
            player.preventsDisplaySleepDuringVideoPlayback = false
            player.isMuted = true
            layer.player = player
            layer.videoGravity = .resizeAspectFill
        }

        func clearObservers() {
            for t in tokens { NotificationCenter.default.removeObserver(t) }
            tokens.removeAll()
        }
    }

    private var slots: [Slot] = []
    private var activeSlot = 0

    /// 实际播放顺序（shuffle 时已洗牌）
    private var playlist: [URL] = []
    private var playlistIndex = 0
    /// 防止"切到一半又收到结束通知"导致连跳多个
    private var isAdvancing = false

    private var videoSettings = Params.Video()
    private var paused = false

    /// 上次实际生效的配置指纹（视频路径 + 倍速实际值）
    private var appliedKey = ""

    private let dimLayer = CALayer()
    private let hintLabel = NSTextField(labelWithString: "")
    private var progressTimer: Timer?
    private var selfTestStarted = false

    /// macOS 14+：只用来向系统声明期望刷新率
    private var frameRateLink: AnyObject?
    private var tickCount = 0
    private var tickWindowStart = 0.0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.opacity = 0
        layer?.addSublayer(dimLayer)

        hintLabel.alignment = .center
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        hintLabel.font = .systemFont(ofSize: 18)   // 与设置界面同节奏（原 16，大两号）
        hintLabel.maximumNumberOfLines = 5
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.isHidden = true
        addSubview(hintLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: 倍速策略

    /// > 2× 必须烘焙进时间轴，否则 AVPlayer 会停摆
    private var usesBakedSpeed: Bool { videoSettings.speed > 2.0 }

    /// 播放器实际该设的 rate：烘焙过就是 1×
    private var playbackRate: Float { usesBakedSpeed ? 1.0 : Float(videoSettings.speed) }

    private var active: Slot? {
        slots.indices.contains(activeSlot) ? slots[activeSlot] : slots.first
    }

    /// 当前正在播放的视频（活跃槽位的 URL）。
    /// ⚠️ 不要用 playlist.first 代替它 —— 轮播推进后两者并不相同。
    private var currentPlaylistURL: URL? {
        guard playlist.indices.contains(playlistIndex) else { return active?.url }
        return playlist[playlistIndex]
    }

    // MARK: 应用设置

    func apply(_ settings: Settings) {
        let v = settings.video
        let usable = v.availableURLs              // 已按设置里的顺序，且过滤掉失效文件

        // ⚠️ 指纹必须含**倍速的实际值**。曾经只放"是否需要烘焙"的布尔量，
        //    导致 3×→5× 指纹不变、不重建，3/4/5× 全按第一次的 3× 播。
        //    也含 shuffle：勾选/取消随机播放要重新洗牌。
        let key = "\(usable.map(\.path).joined(separator: "|"))#speed\(v.speed)#shuffle\(v.shuffle)"

        // ⚠️ 判断"是不是同一个视频"必须拿**当前正在播的那个**来比，
        //    不能拿 usable.first。轮播到第 3 个时改倍速，
        //    usable.first 仍是列表第一个，会被误判成"换了视频"——
        //    于是重建时从 playlist[0] 开始播，用户看到"改倍速把视频切走了"。
        let playingNow = active?.url
        let sameVideo = slots.isEmpty == false && playingNow != nil && playingNow == currentPlaylistURL
        let needsRebuild = (key != appliedKey)
        let savedPosition = (needsRebuild && sameVideo) ? currentSourcePosition() : 0

        // 先记下旧的 shuffle，稍后用来判断"随机开关是否被改动"
        let shuffleBefore = videoSettings.shuffle
        videoSettings = v

        guard let url = usable.first else {
            teardown()
            appliedKey = key
            let configured = !v.urls.isEmpty
            if configured {
                showHint("""
                视频文件找不到了
                它可能已被移动、重命名或删除

                菜单栏 ✨ → 选择视频…
                """)
            } else {
                showHint("""
                还没有选择视频

                菜单栏 ✨ → 选择视频…
                或把视频文件拖到设置窗口
                """)
            }
            Log.warn("视频壁纸：无可用视频（\(configured ? "已配置但文件不存在" : "尚未配置")）")
            return
        }

        if !needsRebuild, !slots.isEmpty {
            applyLiveSettings(v)              // 音量/压暗/填充这类就地更新
            return
        }

        appliedKey = key
        hideHint()

        // 成员集合是否变了（改选了别的视频 / 失效被剔除）
        let sameMembers = playlist.count == usable.count
            && Set(playlist.map(\.path)) == Set(usable.map(\.path))
        let shuffleChanged = v.shuffle != shuffleBefore

        // 建立播放顺序。
        // ⚠️ 只在「成员变了」或「随机开关变了」时才重新生成列表 ——
        //    单纯改倍速不该重洗、也不该重置轮播进度，
        //    否则轮播到一半调速度，顺序会莫名其妙重来一遍。
        if !sameMembers || shuffleChanged || playlist.isEmpty {
            playlist = v.shuffle ? usable.shuffled() : usable
            // 尽量保持"继续播当前这个"，只有它已不在列表里才回到开头
            if let now = playingNow, let idx = playlist.firstIndex(of: now) {
                playlistIndex = idx
            } else {
                playlistIndex = 0
            }
        }

        let target = playlist.indices.contains(playlistIndex) ? playlist[playlistIndex] : playlist[0]
        load(url: target, resumeAt: savedPosition, switching: sameVideo)

        startProgressLogging()
        startSpeedSelfTestIfRequested()

        if playlist.count > 1 {
            Log.info("播放列表共 \(playlist.count) 个，\(v.shuffle ? "随机顺序" : "按文件名顺序")，播完自动切下一个")
        }
    }

    // MARK: 双缓冲装载

    /// 在**非活跃**槽位上准备新内容，等它出帧后再交换可见性。
    /// 全程旧槽位一直显示画面，所以屏幕不会黑。
    private func load(url: URL, resumeAt position: Double, switching: Bool, onSwapped: (() -> Void)? = nil) {
        // 选目标槽位：首次用 0；否则用另一个（不存在就补建）
        let targetIndex: Int
        if slots.isEmpty {
            slots = [Slot()]
            installLayer(slots[0].layer, below: dimLayer)
            targetIndex = 0
            activeSlot = 0
        } else if slots.count == 1 {
            slots.append(Slot())
            targetIndex = 1
        } else {
            targetIndex = 1 - activeSlot
        }

        let slot = slots[targetIndex]
        slot.clearObservers()

        let item = makeItem(for: url, speed: videoSettings.speed)
        slot.bakedSpeed = (videoSettings.speed > 2.0) ? videoSettings.speed : 1.0
        slot.url = url

        // 若目标槽位不是当前可见的那个，就把它设为不可见并提到最上层，
        // 这样交换时不会被旧层压住，而且换 item 造成的黑也看不见。
        let willSwap = (targetIndex != activeSlot)
        if willSwap {
            slot.layer.opacity = 0
            if let old = active?.layer {
                layer?.insertSublayer(slot.layer, above: old)
            } else {
                installLayer(slot.layer, below: dimLayer)
            }
        }
        slot.layer.frame = bounds

        slot.player.replaceCurrentItem(with: item)
        slot.player.isMuted = videoSettings.volume <= 0.001
        slot.player.volume = Float(videoSettings.volume)

        installObservers(for: slot, item: item, url: url)

        // 先定位再起播，避免从 0 闪到目标位置
        let factor = slot.bakedSpeed > 1.001 ? slot.bakedSpeed : 1.0
        let target = position / factor
        // ⚠️ 用 item.asset.duration 而不是 item.duration：
        //    AVPlayerItem(url:) 刚创建时 item.duration 还是 invalid，
        //    判定会失败并退回"从头播放" —— 表现就是从 5× 切到 1.5× 时跳回开头。
        //    asset.duration 是同步可用的，两种 item 都能立刻拿到。
        let dur = CMTimeGetSeconds(item.asset.duration)
        if switching, position > 0.5, dur.isFinite, dur > 0, target < dur - 0.1 {
            slot.player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                             toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                guard let self, !self.paused else { return }
                slot.player.playImmediately(atRate: self.playbackRate)
            }
            Log.info(String(format: "保持播放进度：源 %.1fs → 新时间轴 %.1fs（%.1f×，未从头开始）",
                            position, target, videoSettings.speed))
        } else {
            startSlot(slot, fromZero: true)
        }

        Log.info(String(format: "视频壁纸：循环播放 %@  %.1f×  %@",
                        url.lastPathComponent, videoSettings.speed,
                        slot.bakedSpeed > 1.001 ? "（倍速已烘焙进时间轴）" : "（直接倍速播放）"))

        guard willSwap else {
            logRate("开始播放")
            onSwapped?()
            return
        }

        // 等新槽位真正出帧，再交换可见性（旧层在此之前一直显示着）
        waitUntilReady(slot) { [weak self] in
            guard let self else { return }
            let oldIndex = self.activeSlot
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            slot.layer.opacity = 1
            if self.slots.indices.contains(oldIndex), oldIndex != targetIndex {
                let old = self.slots[oldIndex]
                old.layer.opacity = 0
                // 此时才释放旧解码器 —— 它的画面已被完全接替
                old.player.pause()
                old.player.replaceCurrentItem(with: nil)
                old.clearObservers()
                old.url = nil
            }
            CATransaction.commit()
            self.activeSlot = targetIndex
            self.logRate("切换完成")
            onSwapped?()
        }
    }

    /// 等槽位真正有画面：图层就绪且时间轴在推进
    private func waitUntilReady(_ slot: Slot, then done: @escaping () -> Void) {
        var tries = 0
        let timer = Timer(timeInterval: 0.02, repeats: true) { t in
            tries += 1
            let timeOK = CMTimeGetSeconds(slot.player.currentTime()) > 0
            let ready = slot.layer.isReadyForDisplay
            // 最多等 1 秒，避免异常情况下画面永远停在旧内容
            if (ready && timeOK) || tries > 50 {
                t.invalidate()
                done()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func installLayer(_ l: AVPlayerLayer, below reference: CALayer) {
        l.frame = bounds
        l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.insertSublayer(l, below: reference)
    }

    /// 建 item。倍速 > 2× 时返回时间轴已压缩的 composition item。
    private func makeItem(for url: URL, speed: Double) -> AVPlayerItem {
        guard speed > 2.0 else { return AVPlayerItem(url: url) }

        let asset = AVURLAsset(url: url)
        guard let src = asset.tracks(withMediaType: .video).first else {
            Log.warn("读取视频轨道失败，退回直接倍速：\(url.lastPathComponent)")
            return AVPlayerItem(url: url)
        }
        let full = CMTimeRange(start: .zero, duration: asset.duration)
        let comp = AVMutableComposition()
        guard let track = comp.addMutableTrack(withMediaType: .video,
                                              preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return AVPlayerItem(url: url)
        }
        do {
            try track.insertTimeRange(full, of: src, at: .zero)
        } catch {
            Log.warn("组装 composition 失败，退回直接倍速：\(error)")
            return AVPlayerItem(url: url)
        }
        let compressed = CMTimeMultiplyByFloat64(asset.duration, multiplier: 1.0 / speed)
        track.scaleTimeRange(full, toDuration: compressed)
        Log.info(String(format: "倍速 %.1f× 超过 AVPlayer 的 2× 上限 → 已烘焙进时间轴："
                              + "%.1fs 压缩为 %.1fs，播放器跑 1×",
                        speed, CMTimeGetSeconds(asset.duration), CMTimeGetSeconds(compressed)))
        return AVPlayerItem(asset: comp)
    }

    private func installObservers(for slot: Slot, item: AVPlayerItem, url: URL) {
        // 播放结束 → 列表里还有下一个就切过去；只有一个就原地循环。
        // （不用 AVPlayerLooper，理由见文件头）
        let endToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak slot] _ in
            guard let self, let slot, !self.paused, slot === self.active,
                  !self.isAdvancing else { return }

            if self.playlist.count > 1 {
                self.advanceToNext(reason: "播放结束")
            } else {
                slot.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                slot.player.playImmediately(atRate: self.playbackRate)
            }
        }
        slot.tokens.append(endToken)

        let failToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { note in
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Log.error("视频播放失败 \(url.lastPathComponent)：\(err?.localizedDescription ?? "未知错误")")
        }
        slot.tokens.append(failToken)
    }

    /// 「下一幅」按钮：手动切到下一个视频。
    func skipToNext() {
        guard playlist.count > 1 else {
            Log.info("只有一个视频，「下一幅」不生效")
            return
        }
        advanceToNext(reason: "手动切下一幅")
    }

    /// 切到播放列表的下一个。复用双缓冲：新内容在不可见槽位就绪后才交换，
    /// 所以轮播切换期间屏幕上始终是上一个视频的画面，不会闪黑。
    private func advanceToNext(reason: String) {
        guard playlist.count > 1, !isAdvancing else { return }
        isAdvancing = true

        playlistIndex = (playlistIndex + 1) % playlist.count
        let next = playlist[playlistIndex]
        Log.info("轮播切换（\(reason)）→ \(next.lastPathComponent)  [\(playlistIndex + 1)/\(playlist.count)]")

        // resumeAt: 0 —— 轮到谁就从它自己的开头播。
        // ⚠️ 在新槽位真正就绪并完成交换后才解除标记，
        //    不能靠固定延时：延时太短会被上个视频的收尾通知再次触发、
        //    连跳好几个；太长又会卡住后续轮播。
        load(url: next, resumeAt: 0, switching: false) { [weak self] in
            self?.isAdvancing = false
        }
    }

    private func startSlot(_ slot: Slot, fromZero: Bool) {
        if fromZero { slot.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) }
        guard !paused else { return }
        slot.player.playImmediately(atRate: playbackRate)
    }

    // MARK: 进度保持（改倍速不从头开始）

    /// 活跃槽位当前进度换算成「源视频秒数」。
    /// 时间轴被压缩了 1/倍速，所以源位置 = currentTime × 倍速。
    private func currentSourcePosition() -> Double {
        guard let slot = active, slot.player.currentItem != nil else { return 0 }
        let t = CMTimeGetSeconds(slot.player.currentTime())
        guard t.isFinite, t > 0 else { return 0 }
        return t * (slot.bakedSpeed > 1.001 ? slot.bakedSpeed : 1.0)
    }

    // MARK: 就地更新

    private func applyLiveSettings(_ v: Params.Video) {
        dimLayer.opacity = Float(v.dim)
        for slot in slots {
            slot.player.isMuted = v.volume <= 0.001
            slot.player.volume = Float(v.volume)
            // rate == 0 表示已暂停，此时设 rate 会把它"叫醒"，所以只在播放中改
            if slot.player.rate != 0 { slot.player.rate = playbackRate }
            slot.layer.videoGravity = gravity(for: v.fillMode)
        }

        // 兜底自检：活跃播放器的状态必须与设定的倍速区间一致
        guard let slot = active, slot.player.currentItem != nil else { return }
        let bakedNow = slot.player.currentItem?.asset is AVComposition
        if bakedNow != usesBakedSpeed {
            Log.error("倍速区间与播放器状态不一致：设定 \(v.speed)×（\(usesBakedSpeed ? "应烘焙" : "应直接倍速")），"
                      + "实际 \(bakedNow ? "已烘焙" : "未烘焙")")
        }
    }

    private func gravity(for mode: Params.Video.FillMode) -> AVLayerVideoGravity {
        switch mode {
        case .fill:    return .resizeAspectFill
        case .fit:     return .resizeAspect
        case .stretch: return .resize
        }
    }

    // MARK: 日志

    private func logRate(_ when: String) {
        guard let slot = active else { return }
        Log.info(String(format: "播放速率 %@：设定 %.2f×  播放器 %.2f×  在播=%@",
                        when, videoSettings.speed, Double(slot.player.rate),
                        slot.player.rate != 0 ? "是" : "否"))
    }

    /// 定期记录播放进度。时间轴推进是否均匀，是判断"有没有在卡"最直接的内部证据。
    private func startProgressLogging() {
        progressTimer?.invalidate()
        var last = 0.0
        var lastWall = CACurrentMediaTime()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, !self.paused, let slot = self.active,
                  slot.player.rate != 0 else { return }
            let now = CMTimeGetSeconds(slot.player.currentTime())
            guard now.isFinite else { return }
            let wall = CACurrentMediaTime()
            let dt = wall - lastWall
            let advanced = now - last
            // 烘焙过的时间轴已被压缩，真实推进 = advanced × bakedSpeed；
            // 未烘焙时 currentTime 本身就按 rate 推进，直接取比值
            let baked = slot.bakedSpeed > 1.001
            let effective = dt > 0 ? (baked ? advanced * slot.bakedSpeed / dt : advanced / dt) : 0
            if last > 0 {
                let target = baked ? slot.bakedSpeed : self.videoSettings.speed
                let dev = target > 0 ? abs(effective - target) / target : 0
                if dev > 0.08 {
                    Log.warn(String(format: "播放速度偏离：实际等效 %.2f×，设定 %.2f×（%@）",
                                    effective, target, baked ? "时间轴烘焙" : "直接倍速"))
                }
            }
            last = now
            lastWall = wall
        }
        RunLoop.main.add(t, forMode: .common)
        progressTimer = t
    }

    /// 自测钩子：LUMINA_SELFTEST=3,5,2 时按序自动切换倍速，
    /// 验证"运行时改倍速能重建内容、不丢进度、不闪黑"，无需人工点界面。
    private func startSpeedSelfTestIfRequested() {
        guard !selfTestStarted else { return }
        guard let raw = ProcessInfo.processInfo.environment["LUMINA_SELFTEST"], !raw.isEmpty else { return }
        selfTestStarted = true
        let steps = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard steps.count > 1 else { return }
        // 间隔可用 LUMINA_SELFTEST_GAP 覆盖（默认 8 秒）。
        // 测"轮播中途改倍速"时要把它调到小于单个视频时长。
        let gap = Double(ProcessInfo.processInfo.environment["LUMINA_SELFTEST_GAP"] ?? "") ?? 8.0
        Log.info("自测模式：每 \(Int(gap))s 依次切换 \(steps.map { String(format: "%.1f", $0) }.joined(separator: " → "))×")
        var i = 0
        let timer = Timer(timeInterval: gap, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            i += 1
            guard i < steps.count else {
                t.invalidate()
                Log.info("自测结束")
                return
            }
            let next = steps[i]
            Log.info(String(format: "自测：切到 %.1f×（当前视频 %@，进度 %.1fs）",
                            next, self.currentPlaylistURL?.lastPathComponent ?? "?", self.currentSourcePosition()))
            var v = self.videoSettings
            v.speed = next
            var s = Settings.load()
            s.video = v
            self.apply(s)
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: 高刷声明
    //
    // ⚠️ 高倍速顺滑的关键。解码器按「源帧率 × 倍速」产帧，30fps 素材 @4× 就是
    // 120 帧/秒；而 macOS 上 AppKit 窗口**默认不跑满 ProMotion 的 120Hz，必须显式申请**，
    // 否则产帧速率与上屏速率对不上，多余的帧被不均匀丢掉 → 看起来一卡一卡。
    //
    // macOS 没有 `CALayer.preferredFrameRateRange`（那是 iOS 的 API），
    // 只能用 `NSView.displayLink` 把期望帧率告诉系统。
    private func installDisplayLinkIfNeeded() {
        guard #available(macOS 14.0, *) else { return }
        guard frameRateLink == nil, window != nil else { return }
        let maxHz = Float(window?.screen?.maximumFramesPerSecond
                          ?? NSScreen.main?.maximumFramesPerSecond ?? 60)
        let link = displayLink(target: self, selector: #selector(frameRateTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maxHz, preferred: maxHz)
        link.add(to: .main, forMode: .common)
        frameRateLink = link
        Log.info(String(format: "已声明期望刷新率：最高 %.0fHz（窗口默认可能只有 60Hz）", maxHz))
    }

    @objc private func frameRateTick() {
        // 实测回调频率 == 系统真正给这个窗口的刷新率，
        // 这是验证"高刷请求到底有没有生效"的唯一直接证据。
        tickCount += 1
        let now = CACurrentMediaTime()
        if tickWindowStart == 0 { tickWindowStart = now; return }
        let elapsed = now - tickWindowStart
        if elapsed >= 3.0 {
            let hz = Double(tickCount) / elapsed
            Log.info(String(format: "display link 实测 %.1f Hz（%d 次回调 / %.1f 秒）%@",
                            hz, tickCount, elapsed,
                            hz > 90 ? "→ 高刷已生效" : "→ 仍被限在 60Hz 档"))
            tickCount = 0
            tickWindowStart = now
        }
    }

    // MARK: 暂停 / 恢复

    func setPaused(_ paused: Bool) {
        self.paused = paused
        for slot in slots where slot.player.currentItem != nil {
            if paused {
                slot.player.pause()
            } else if slot === active {
                // ⚠️ 必须用 playImmediately(atRate:)，用 play() 会把速度重置成 1×
                slot.player.playImmediately(atRate: playbackRate)
            }
        }
        logRate(paused ? "暂停" : "恢复")
    }

    // MARK: 提示

    private func showHint(_ text: String) {
        hintLabel.stringValue = text
        hintLabel.isHidden = false
        needsLayout = true
    }

    private func hideHint() { hintLabel.isHidden = true }

    // MARK: 布局

    override func layout() {
        super.layout()
        installDisplayLinkIfNeeded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.frame = bounds
        for slot in slots { slot.layer.frame = bounds }
        CATransaction.commit()

        let w = min(560, max(200, bounds.width - 80))
        let h: CGFloat = 120
        hintLabel.frame = CGRect(x: (bounds.width - w) / 2,
                                 y: (bounds.height - h) / 2,
                                 width: w, height: h)
    }

    // MARK: 清理

    private func teardown() {
        progressTimer?.invalidate(); progressTimer = nil
        for slot in slots {
            slot.clearObservers()
            slot.player.pause()
            slot.player.replaceCurrentItem(with: nil)   // 释放解码器与文件句柄
            slot.layer.removeFromSuperlayer()
        }
        slots.removeAll()
        activeSlot = 0
        playlist = []
        playlistIndex = 0
        isAdvancing = false
    }

    deinit { teardown() }
}