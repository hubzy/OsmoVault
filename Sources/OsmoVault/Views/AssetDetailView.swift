import SwiftUI
import AVFoundation
import AppKit

/// AVPlayerLayer 视图，替代 AVKit VideoPlayer（后者在 CommandLineTools 工具链下会崩溃）
struct LayerPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerNSView {
        let v = PlayerLayerNSView()
        v.wantsLayer = true
        v.attach(player)
        return v
    }

    func updateNSView(_ nsView: PlayerLayerNSView, context: Context) {}
}

final class PlayerLayerNSView: NSView {
    /// 直接把 AVPlayerLayer 作为 backing layer，少一层子图层，渲染路径最短
    override func makeBackingLayer() -> CALayer {
        let l = AVPlayerLayer()
        l.videoGravity = .resizeAspect
        // 背景留空：画面外的信箱区直接透出窗口底色，不要硬编码黑色
        l.backgroundColor = nil
        return l
    }

    private var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

    func attach(_ player: AVPlayer) {
        wantsLayer = true
        playerLayer?.player = player
        playerLayer?.frame = bounds
    }

    override func layout() {
        super.layout()
        playerLayer?.frame = bounds
    }
}

// MARK: - 详情面板

/// 右侧面板分区：库位置条 → 画面区 → 播放操作区 → 信息区 → 功能区
struct AssetDetailView: View {
    let asset: Asset
    /// 故意不用 @ObservedObject：时间变化只应重绘控制条和画面，不该每 0.25s 重排整个面板
    let controller: PlayerController
    var onRate: ((Int64, Int) -> Void)?
    var onColor: ((Int64, Int) -> Void)?
    var onToggleFavorite: (() -> Void)?
    var onGrab: (() -> Void)?
    var onDelete: (() -> Void)?
    /// 手动补定位（没有 GPS 的素材也能在地图上找到）
    var onEditLocation: (() -> Void)?
    /// 正在全屏播放。**必须为 true 时把画面区从视图树里移掉**：
    /// 一个 AVPlayer 同时只能挂一个 AVPlayerLayer（后挂的赢，前一个直接变黑），
    /// 两处同时渲染会让画面和还原后的详情页都黑掉
    var isTheater: Bool = false
    var onToggleTheater: (() -> Void)?
    /// LocationEditorSheet 打开时置 false：详情里的裸字母 S 不能抢走经纬度输入框的按键
    var shortcutsEnabled: Bool = true

    /// 播放器还没报告真实尺寸时，先用素材库里记录的宽高兜底
    private var fallbackRatio: CGFloat {
        let w = CGFloat(asset.width), h = CGFloat(asset.height)
        guard w > 0, h > 0 else { return 16.0 / 9.0 }
        return w / h
    }

    /// 实况照片是否正在播放。换素材时归零，避免上一条的播放态带过来
    @State private var livePlaying = false

    /// 画面区按类型切换：视频走播放器，照片/实况走静态大图（实况可叠加播放）
    @ViewBuilder
    private var stage: some View {
        switch asset.kind {
        case .video:
            PlayerStage(controller: controller, fallbackRatio: fallbackRatio)
        case .photo:
            PhotoStage(asset: asset)
        case .livePhoto:
            LivePhotoStage(asset: asset, controller: controller,
                           fallbackRatio: fallbackRatio, playing: $livePlaying)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 画面区：吃掉剩余空间，窄窗口下也不低于 160。
            // 全屏播放期间整块让位（见 isTheater 的注释），退出全屏后重新创建、重新 attach
            if !isTheater {
                ZStack(alignment: .topTrailing) {
                    stage
                        .frame(minHeight: 160)
                        .padding(.vertical, 8)

                    if let onToggleTheater {
                        Button(action: onToggleTheater) {
                            // 玻璃只做 HUD 外壳；按钮本体仍是系统 .plain
                            VaultGlassContainer(radius: Vault.R.media,
                                                padding: Vault.S.compact,
                                                material: .ultraThinMaterial) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("全屏播放（⌘↩）")
                        .accessibilityLabel(Text("全屏播放"))
                        .padding(.top, 16)
                        .padding(.trailing, 10)
                    }
                }
            }

            Divider()

            // 播放操作区：纯照片没有可播的东西，整块不显示
            if asset.kind != .photo {
                VStack(alignment: .leading, spacing: 6) {
                    ZoneHeader(asset.kind == .livePhoto ? "实况" : "播放")
                    if asset.kind == .livePhoto {
                        LivePhotoBar(controller: controller, playing: $livePlaying,
                                     seconds: asset.durationSeconds)
                    } else {
                        TransportBar(controller: controller)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()
            }

            // 功能区：图标 + 文字横向居中
            VStack(alignment: .leading, spacing: 6) {
                ZoneHeader("操作")
                ActionSection(asset: asset,
                              onGrab: onGrab,
                              onToggleFavorite: onToggleFavorite,
                              onDelete: onDelete,
                              shortcutsEnabled: shortcutsEnabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // 信息区
            VStack(alignment: .leading, spacing: 8) {
                ZoneHeader("信息")
                InfoSection(asset: asset, onRate: onRate, onColor: onColor,
                            onEditLocation: onEditLocation)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // 换素材时停掉上一条的实况
        .onChange(of: asset.id) { _, _ in
            livePlaying = false
        }
        // 详情面板被移出视图层级（切到地图 / 回收站 / 一键出片 / 重复素材，或关窗口）时
        // 必须把播放器停住：AVPlayer 不属于视图，视图没了声音照样会放下去。
        // 用 pause 而不是 unload：回来时 .onAppear 的 load() 会因为路径相同直接返回，
        // 于是停在暂停状态，不会一回到图库就又开始播
        .onDisappear { controller.pause() }
    }
}

private extension NSImage {
    var ratio: CGFloat { size.height > 0 ? size.width / size.height : 0 }
}

// MARK: - 分区小标题

private struct ZoneHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption)
            .bold()
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 画面区

/// 画面舞台：在可用空间内按真实宽高比取最大内接矩形，上下左右居中
private struct PlayerStage: View {
    @ObservedObject var controller: PlayerController
    let fallbackRatio: CGFloat

    private var ratio: CGFloat { controller.videoRatio ?? fallbackRatio }

    var body: some View {
        GeometryReader { geo in
            let fitted = Self.fit(in: geo.size, ratio: ratio)
            LayerPlayerView(player: controller.player)
                .frame(width: fitted.width, height: fitted.height)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                // 外层给满容器尺寸，内层 frame 自然居中
                .frame(width: geo.size.width, height: geo.size.height)
        }
        // 不铺底色：留空即可透出窗口/分栏的背景色，画面四周不再是一块突兀的纯黑
    }

    /// 横屏按宽度撑满、竖屏按高度撑满，两者都不会溢出
    private static func fit(in size: CGSize, ratio: CGFloat) -> CGSize {
        guard size.width > 1, size.height > 1, ratio > 0 else { return .zero }
        let width = min(size.width, size.height * ratio)
        return CGSize(width: width, height: width / ratio)
    }
}

// MARK: - 照片画面区

/// 静态图舞台：同样按真实比例居中最大化，边界处理与 PlayerStage 一致
private struct PhotoStage: View {
    let asset: Asset
    @State private var image: NSImage?
    /// 记录 image 属于哪一条素材。
    /// 从一张图翻到另一张时，外层 switch 走的是同一个分支、视图结构没变，SwiftUI 会**复用**这个
    /// 视图实例，@State 里还挂着上一张图 —— 原来只判断 `image == nil` 就直接 return，
    /// 结果翻到第二张显示的还是第一张。必须按素材 id 判断要不要重新加载。
    @State private var loadedID: Int64?

    private var ratio: CGFloat {
        let w = CGFloat(asset.width), h = CGFloat(asset.height)
        guard w > 0, h > 0 else { return 4.0 / 3.0 }
        return w / h
    }

    var body: some View {
        GeometryReader { geo in
            let fitted = fit(in: geo.size, ratio: image?.ratio ?? ratio)
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
            }
            .frame(width: fitted.width, height: fitted.height)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: asset.id) {
            guard loadedID != asset.id else { return }
            // 先回到占位态：不让上一张图继续挂在新素材的画面区上。
            // 但直接清空会白一下 —— 网格缩略图基本都已缓存，先拿它顶上再换大图
            image = ThumbnailStore.shared.cachedThumbnail(for: asset)
            guard !Task.isCancelled else { return }
            let loaded = await ThumbnailStore.shared.largeImage(for: asset)
            // 连续快翻时旧任务可能后返回，只认最后一次请求的那条
            guard !Task.isCancelled else { return }
            loadedID = asset.id
            image = loaded ?? image
        }
    }

    private func fit(in size: CGSize, ratio: CGFloat) -> CGSize {
        guard size.width > 1, size.height > 1, ratio > 0 else { return .zero }
        let width = min(size.width, size.height * ratio)
        return CGSize(width: width, height: width / ratio)
    }
}

/// 实况照片：底图是静态图，播放时在下面叠播放器。
///
/// 交互照系统照片应用的规范来：
/// - 画面**左上角**常驻 LIVE 标记，点它可以把实况关掉（变成带斜杠的图标，静止图）
/// - 鼠标悬停自动播放动态片段，移开停回静态图；点画面也能手动播/停
private struct LivePhotoStage: View {
    let asset: Asset
    let controller: PlayerController
    let fallbackRatio: CGFloat
    @Binding var playing: Bool

    /// 实况开关。关掉后就是一张普通静态图，hover 也不播
    @State private var liveEnabled = true

    private var ratio: CGFloat {
        let w = CGFloat(asset.width), h = CGFloat(asset.height)
        guard w > 0, h > 0 else { return 4.0 / 3.0 }
        return w / h
    }

    var body: some View {
        GeometryReader { geo in
            // 按素材比例算出画面框：LIVE 标记要贴在**图片**的左上角，
            // 而不是整个舞台（舞台比图片宽/高时贴边会跑到信箱区里）
            let fitted = Self.fit(in: geo.size, ratio: ratio)
            ZStack {
                // 悬停 / 点击只作用在**图片框本身**：舞台比图片大时四周会有信箱留白，
                // 鼠标落在留白区域不再误触发实况播放 —— 必须移到图片上才开始播
                ZStack(alignment: .topLeading) {
                    PhotoStage(asset: asset)
                    if playing {
                        PlayerStage(controller: controller, fallbackRatio: fallbackRatio)
                    }
                    LiveBadge(enabled: liveEnabled, playing: playing) { toggleLive() }
                        .padding(8)
                }
                .frame(width: fitted.width, height: fitted.height)
                .contentShape(Rectangle())
                .onHover { hovering in
                    guard liveEnabled else { return }
                    if hovering {
                        start()
                    } else if playing {
                        stop()
                    }
                }
                .onTapGesture {
                    guard liveEnabled else { return }
                    if playing { stop() } else { start() }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onChange(of: asset.id) { _, _ in liveEnabled = true }
        .onDisappear { stop() }
    }

    private func toggleLive() {
        liveEnabled.toggle()
        if !liveEnabled { stop() }
    }

    private func start() {
        guard !playing else { return }
        playing = true
        // 声音按「实况开关」来，别被之前播过的视频带成有声
        controller.syncLiveAudio()
        controller.playFromStart()
    }

    private func stop() {
        guard playing else { return }
        playing = false
        controller.pause()
    }

    private static func fit(in size: CGSize, ratio: CGFloat) -> CGSize {
        guard size.width > 1, size.height > 1, ratio > 0 else { return .zero }
        let width = min(size.width, size.height * ratio)
        return CGSize(width: width, height: width / ratio)
    }
}

/// 实况照片的操作条：只留播放/停止 + 时长，不需要逐帧、倍速那套
private struct LivePhotoBar: View {
    @ObservedObject var controller: PlayerController
    @Binding var playing: Bool
    let seconds: Double

    var body: some View {
        HStack(spacing: 10) {
            Button {
                playing.toggle()
                if playing {
                    controller.playFromStart()
                } else {
                    controller.pause()
                }
            } label: {
                Image(systemName: playing ? "stop.fill" : "play.fill")
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .help(playing ? "停止" : "播放实况")
            .accessibilityLabel(Text(playing ? "停止" : "播放实况"))
            .frame(width: 28)

            Text(seconds > 0 ? "实况片段 \(String(format: "%.1f", seconds)) 秒" : "实况片段")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            // 实况照片默认无声：悬停自动播时不该突然出声，需要声音才手动开
            Button {
                controller.setLiveAudio(!controller.liveAudioEnabled)
            } label: {
                Image(systemName: controller.liveAudioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            .buttonStyle(.borderless)
            .help(controller.liveAudioEnabled ? "关闭实况声音" : "开启实况声音")
            .accessibilityLabel(Text(controller.liveAudioEnabled ? "关闭实况声音" : "开启实况声音"))
            .frame(width: 26)
        }
        // 离开这张素材时停掉，避免下一条素材继续在后台播
        .onDisappear {
            playing = false
            controller.pause()
        }
    }
}

// MARK: - 播放操作区

/// 控制条：进度 + 逐帧 + 倍速 + 音量 + 循环。截帧按钮不在这里，归到功能区
private struct TransportBar: View {
    @ObservedObject var controller: PlayerController

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(fmt(controller.currentTime)).font(.caption.monospacedDigit())
                Slider(
                    value: Binding(
                        get: { controller.currentTime },
                        set: { controller.currentTime = $0 }
                    ),
                    in: 0...max(controller.duration, 0.1)
                ) { editing in
                    controller.isScrubbing = editing
                    // 松手才真正 seek，拖动过程中不打断播放
                    if !editing { controller.seek(to: controller.currentTime) }
                }
                Text(fmt(controller.duration)).font(.caption.monospacedDigit())
            }
            .disabled(controller.duration <= 0)

            // 详情列被拖窄时按实测宽度分档降级：先砍 ±5 秒，再砍音量滑块
            GeometryReader { geo in
                if geo.size.width > 360 {
                    controlRow(compact: false)
                } else if geo.size.width > 300 {
                    controlRow(compact: true)
                } else {
                    controlRow(compact: true, dropVolume: true)
                }
            }
            .frame(height: 26)
        }
    }

    /// compact：去掉 ±5 秒跳转；dropVolume：连音量滑块一起去掉
    @ViewBuilder
    private func controlRow(compact: Bool, dropVolume: Bool = false) -> some View {
        HStack(spacing: 4) {
            if !compact {
                icon("gobackward.5", "后退 5 秒") { controller.seek(by: -5) }
            }
            icon("backward.frame", "上一帧") { controller.step(frames: -1) }

            VaultIconButton(controller.isPlaying ? "暂停" : "播放",
                            systemImage: controller.isPlaying ? "pause.fill" : "play.fill",
                            symbolSize: 15, hit: 26) {
                controller.togglePlay()
            }

            icon("forward.frame", "下一帧") { controller.step(frames: 1) }
            if !compact {
                icon("goforward.5", "前进 5 秒") { controller.seek(by: 5) }
            }

            Spacer(minLength: 8)

            VaultIconButton(controller.isMuted ? "取消静音" : "静音",
                            systemImage: controller.volumeIcon,
                            hit: 26) {
                controller.toggleMute()
            }

            if !dropVolume {
                Slider(
                    value: Binding(
                        get: { controller.volumeLevel },
                        set: { controller.setVolume($0) }
                    ),
                    in: 0...1
                )
                .frame(width: 56)
            }

            Menu {
                ForEach(PlayerController.rateOptions, id: \.self) { r in
                    Button {
                        controller.setRate(r)
                    } label: {
                        if abs(controller.playbackRate - r) < 0.01 {
                            Image(systemName: "checkmark")
                        }
                        Text(rateText(r))
                    }
                }
            } label: {
                Text(rateText(controller.playbackRate))
                    .font(.caption.monospacedDigit())
                    .frame(width: 36)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 44)
            .help("播放倍速")

            VaultIconButton(controller.loopEnabled ? "关闭循环" : "开启循环",
                            systemImage: "repeat",
                            tint: controller.loopEnabled ? Color.accentColor : nil,
                            hit: 26) {
                controller.loopEnabled.toggle()
            }
        }
    }

    /// TransportBar 的所有图标按钮一律 hit: 26：保持按钮宽度不变，
    /// GeometryReader 的 >360 / 300~360 / <300 三档降级阈值不会被撑开
    private func icon(_ system: String, _ help: String, action: @escaping () -> Void) -> some View {
        VaultIconButton(help, systemImage: system, hit: 26, action: action)
    }

    private func rateText(_ r: Float) -> String {
        r == 1 ? "1x" : String(format: "%gx", r)
    }

    private func fmt(_ s: Double) -> String {
        let t = Int(max(s, 0).rounded())
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}

// MARK: - 信息区

private struct InfoSection: View {
    let asset: Asset
    var onRate: ((Int64, Int) -> Void)?
    var onColor: ((Int64, Int) -> Void)?
    var onEditLocation: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(asset.fileName)
                .font(.headline)
                .lineLimit(2)
                .help(asset.fileName)

            VStack(spacing: 5) {
                infoRow("类型", asset.kind.name)
                infoRow("时间", recordedText)
                locationRow
                infoRow("规格", specText)
                // 照片没有时长；实况照片的动态部分没抽取过时也不知道多长，别显示 00:00
                if asset.kind != .photo, asset.durationSeconds > 0 { infoRow("时长", durationText) }
                infoRow("大小", sizeText)
                pathRow("路径", asset.filePath)
                if asset.srtPath != nil {
                    infoRow("字幕", "已关联 SRT")
                }
            }

            HStack(spacing: 12) {
                RatingControl(rating: asset.rating, onChange: { onRate?(asset.id ?? 0, $0) })
                ColorLabelControl(label: asset.colorLabel, onChange: { onColor?(asset.id ?? 0, $0) })
                Spacer()
            }
            .padding(.top, 2)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            Text(value)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 地点单独一行：没 GPS 的素材可以在这里手动补，右侧按钮直接编辑
    private var locationRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("地点")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            Text(locationText)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                onEditLocation?()
            } label: {
                Image(systemName: asset.latitude == nil ? "mappin.slash.circle" : "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(asset.latitude == nil ? "手动补定位" : "修改定位")
            .accessibilityLabel(Text(asset.latitude == nil ? "手动补定位" : "修改定位"))
        }
    }

    /// 路径单独一行：中段省略 + 右侧按钮直接在访达中选中该文件
    private func pathRow(_ label: String, _ path: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            Text(abbreviate(path))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: {
                Image(systemName: "arrow.right.circle").font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("在访达中显示")
            .accessibilityLabel(Text("在访达中显示"))
        }
    }

    private var recordedText: String {
        guard let t = asset.recordedAt else { return "未知" }
        return t.formatted(date: .numeric, time: .shortened)
    }

    private var locationText: String {
        if let place = asset.placeName, !place.isEmpty { return place }
        if let lat = asset.latitude, let lon = asset.longitude {
            return String(format: "%.4f, %.4f", lat, lon)
        }
        return "无 GPS"
    }

    private var specText: String {
        var parts: [String] = []
        if asset.width > 0 { parts.append("\(asset.width)×\(asset.height)") }
        if asset.frameRate > 0 { parts.append(String(format: "%.0f fps", asset.frameRate)) }
        if let codec = asset.codec, !codec.isEmpty { parts.append(codec) }
        return parts.isEmpty ? "未知" : parts.joined(separator: " · ")
    }

    private var durationText: String {
        let t = Int(max(asset.durationSeconds, 0).rounded())
        if t >= 3600 { return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) }
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: asset.fileSize, countStyle: .file)
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - 功能区

private struct ActionSection: View {
    let asset: Asset
    var onGrab: (() -> Void)?
    var onToggleFavorite: (() -> Void)?
    var onDelete: (() -> Void)?
    /// LocationEditorSheet 打开时禁用裸字母 S（不改 ⌘S / ⌥S，也不把按钮置灰）
    var shortcutsEnabled: Bool = true

    var body: some View {
        // 图标 + 文字横向排列，整组居中；两侧 Spacer 撑开实现居中
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            // 纯照片没有可截的帧，按钮不给出现（S 快捷键也随之失效）
            if asset.kind != .photo {
                ActionItem(title: "截取实况图", systemImage: "camera.shutter.button",
                           keyEquivalent: shortcutsEnabled ? "s" : nil) {
                    onGrab?()
                }
            }
            // 可见标题缩到 5 字避免 64pt 固定框截断；help / VO 仍用标准全称
            ActionItem(title: "访达中显示", fullTitle: "在访达中显示", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: asset.filePath)])
            }
            ActionItem(title: asset.isFavorite ? "取消收藏" : "收藏",
                       systemImage: asset.isFavorite ? "heart.fill" : "heart",
                       tint: asset.isFavorite ? .pink : nil) {
                onToggleFavorite?()
            }
            // moveToTrash 可恢复：中性色，不加 destructive role、不弹确认
            ActionItem(title: "移到回收站", systemImage: "trash") {
                onDelete?()
            }
            Spacer(minLength: 0)
        }
    }
}

/// 功能区按钮：图标在上、文字在下。
/// 固定 64×46：ActionSection 是 4 按钮 HStack(spacing:6)，4×64+18=274pt < 详情列 minOther 300；
/// 放大到 72 会变成 4×72+18=306pt，窄列直接挤爆，所以这个数值不能动。
private struct ActionItem: View {
    let title: String
    /// help / VoiceOver 用的标准全称（可见标题被缩短时仍读全称）
    var fullTitle: String? = nil
    let systemImage: String
    /// 传入才注册系统快捷键，避免抢走输入框里的按键
    var keyEquivalent: String?
    var tint: Color?
    let action: () -> Void

    /// 可聚焦元素是外层 Button，焦点状态必须挂在这里；挂在 ButtonStyle 的 label
    /// 容器上 FKA 下 binding 可能永远不翻，环不出现。
    @FocusState private var focused: Bool

    private var help: String {
        let base = fullTitle ?? title
        guard let k = keyEquivalent else { return base }
        return "\(base) (\(k.uppercased()))"   // 保留「截取实况图 (S)」括注
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 15))
                    .foregroundStyle(tint ?? .primary)
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // 不再用 minimumScaleFactor：0.8 × 9pt 会缩到 7.2pt，不可读
            }
            .frame(width: 64, height: 46)
            .contentShape(Vault.shape(Vault.R.control))
        }
        // 样式只管 hover / pressed / disabled / fill / 1px 描边，不碰焦点
        .buttonStyle(VaultActionButtonStyle())
        .focused($focused)
        .overlay {
            // 3pt accent 焦点环：画在 label 外层、10pt continuous 同心、不 clipShape。
            // 装饰 Shape 必须禁用命中，否则整片盖住按钮点击。
            Vault.shape(Vault.R.focusRing)
                .stroke(Color.accentColor.opacity(focused ? 0.9 : 0), lineWidth: 3)
                .allowsHitTesting(false)
        }
        .help(help)
        .accessibilityLabel(Text(fullTitle ?? title))
        .modifier(ShortcutModifier(keyEquivalent: keyEquivalent))
    }
}

/// 可选的快捷键挂载（SwiftUI 里没法在 if-let 里直接加修饰符）
private struct ShortcutModifier: ViewModifier {
    let keyEquivalent: String?

    func body(content: Content) -> some View {
        if let key = keyEquivalent, let first = key.first {
            content.keyboardShortcut(KeyEquivalent(first), modifiers: [])
        } else {
            content
        }
    }
}

// MARK: - 全屏播放

/// 窗口级全屏播放：盖住侧边栏与详情，只留画面 + 悬浮控制条。
///
/// 只在这里渲染 `PlayerStage`（即唯一的 AVPlayerLayer），详情里的画面区由
/// `AssetDetailView.isTheater` 移出视图树 —— 两处同时挂同一个 AVPlayer 会互相抢图层。
struct TheaterView: View {
    let asset: Asset
    let controller: PlayerController
    var onExit: () -> Void

    /// 实况照片在全屏里是否播放动态片段
    @State private var livePlaying = false
    /// 控制条自动隐藏：鼠标一动就出来，播放中 2.5s 没动静就淡出
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    private var fallbackRatio: CGFloat {
        let w = CGFloat(asset.width), h = CGFloat(asset.height)
        guard w > 0, h > 0 else { return 16.0 / 9.0 }
        return w / h
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            stage
            controls
        }
        .ignoresSafeArea()
        .onContinuousHover { phase in
            if case .active = phase { showControls() }
        }
        // Esc 退出。窗口被拖出原生全屏时 MainWindowView 也会兜一道
        .onExitCommand(perform: onExit)
        .onAppear(perform: showControls)
        .onDisappear(perform: stopAll)
        // 用方向键换素材时，上一条的实况播放态不要带过来
        .onChange(of: asset.id) { _, _ in
            livePlaying = false
            showControls()
        }
    }

    // MARK: 画面

    @ViewBuilder
    private var stage: some View {
        switch asset.kind {
        case .video:
            PlayerStage(controller: controller, fallbackRatio: fallbackRatio)
                .contentShape(Rectangle())
                .onTapGesture { controller.togglePlay() }
        case .photo:
            PhotoStage(asset: asset)
        case .livePhoto:
            ZStack {
                PhotoStage(asset: asset)
                if livePlaying {
                    PlayerStage(controller: controller, fallbackRatio: fallbackRatio)
                } else {
                    // 全屏里没有「悬停播放」的语境，给一个明确的播放入口
                    Button(action: startLive) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 64))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white.opacity(0.92), .black.opacity(0.35))
                            .shadow(radius: 12)
                    }
                    .buttonStyle(.plain)
                    .help("播放实况")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { livePlaying ? stopLive() : startLive() }
        }
    }

    // MARK: 控制条

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(asset.fileName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                Button(action: onExit) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 兜一道 Esc：onExitCommand 依赖 responder chain，按钮快捷键更稳
                .keyboardShortcut(.escape, modifiers: [])
                .help("退出全屏（Esc）")
                .accessibilityLabel(Text("退出全屏（Esc）"))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(
                LinearGradient(colors: [.black.opacity(0.65), .clear],
                               startPoint: .top, endPoint: .bottom)
            )

            Spacer(minLength: 0)

            bottomBar
                .padding(.horizontal, 22)
                .padding(.bottom, 24)
        }
        // 深色画面上必须走暗色配色，否则浅色主题下控制条文字是黑的、看不见
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .opacity(controlsVisible ? 1 : 0)
        // opacity=0 的视图仍参与命中测试；控制条 2.5s 淡出后必须放行，
        // 否则这条带 Spacer 的 VStack 会拦截 stage 的点击播放/暂停。
        .allowsHitTesting(controlsVisible)
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
    }

    @ViewBuilder
    private var bottomBar: some View {
        switch asset.kind {
        case .photo:
            EmptyView()
        case .livePhoto:
            VaultGlassContainer {
                LivePhotoBar(controller: controller, playing: $livePlaying,
                             seconds: asset.durationSeconds)
            }
            .frame(maxWidth: 520)
        case .video:
            VaultGlassContainer {
                TransportBar(controller: controller)
            }
            .frame(maxWidth: 760)
        }
    }

    // MARK: 行为

    private func showControls() {
        controlsVisible = true
        hideTask?.cancel()
        // 照片没有控制条，别让「自动隐藏」把标题也一起藏了
        guard asset.kind != .photo else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            // 暂停状态保留控制条：用户多半正要操作
            guard controller.isPlaying || livePlaying else { return }
            controlsVisible = false
        }
    }

    private func startLive() {
        guard !livePlaying else { return }
        livePlaying = true
        controller.syncLiveAudio()
        controller.playFromStart()
    }

    private func stopLive() {
        livePlaying = false
        controller.pause()
    }

    private func stopAll() {
        hideTask?.cancel()
        if livePlaying {
            livePlaying = false
            controller.pause()
        }
    }
}

// MARK: - 库位置条

/// 显示当前素材来自哪个文件夹。路径由外部给定（跟随选中素材 / 最近导入），
/// 不带筛选、不带下拉，只保留"在访达中打开"
struct LibraryPathBar: View {
    /// nil 表示还没导入过
    let path: String?
    /// 该文件夹下的素材数
    let assetCount: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(.secondary)
                .help("素材所在位置")

            if let path {
                Text(abbreviate(path))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)

                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                } label: {
                    Image(systemName: "arrow.up.forward.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("在访达中打开该文件夹")
                .accessibilityLabel(Text("在访达中打开该文件夹"))
            } else {
                Text("尚未导入文件夹")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Text("\(assetCount) 个素材")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
    }

    /// 家目录缩写为 ~，长路径靠 truncationMode(.middle) 省略
    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
