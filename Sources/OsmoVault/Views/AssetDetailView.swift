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
            // 画面区：吃掉剩余空间，窄窗口下也不低于 160
            stage
                .frame(minHeight: 160)
                .padding(.vertical, 8)

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
                              onDelete: onDelete)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // 信息区
            VStack(alignment: .leading, spacing: 8) {
                ZoneHeader("信息")
                InfoSection(asset: asset, onRate: onRate, onColor: onColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // 换素材时停掉上一条的实况
        .onChange(of: asset.id) { _, _ in
            livePlaying = false
        }
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
                .clipShape(RoundedRectangle(cornerRadius: 6))
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
            .clipShape(RoundedRectangle(cornerRadius: 6))
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

/// 实况照片：底图是静态图，播放时在上面叠播放器
private struct LivePhotoStage: View {
    let asset: Asset
    let controller: PlayerController
    let fallbackRatio: CGFloat
    @Binding var playing: Bool

    var body: some View {
        ZStack {
            PhotoStage(asset: asset)
            if playing {
                PlayerStage(controller: controller, fallbackRatio: fallbackRatio)
            }
        }
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
            .frame(width: 28)

            Text(seconds > 0 ? "实况片段 \(String(format: "%.1f", seconds)) 秒" : "实况片段")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button {
                controller.toggleMute()
            } label: {
                Image(systemName: controller.volumeIcon)
            }
            .buttonStyle(.borderless)
            .help(controller.isMuted ? "取消静音" : "静音")
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

            Button {
                controller.togglePlay()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .help(controller.isPlaying ? "暂停" : "播放")
            .frame(width: 28)

            icon("forward.frame", "下一帧") { controller.step(frames: 1) }
            if !compact {
                icon("goforward.5", "前进 5 秒") { controller.seek(by: 5) }
            }

            Spacer(minLength: 8)

            Button {
                controller.toggleMute()
            } label: {
                Image(systemName: controller.volumeIcon)
            }
            .buttonStyle(.borderless)
            .help(controller.isMuted ? "取消静音" : "静音")
            .frame(width: 26)

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

            Button {
                controller.loopEnabled.toggle()
            } label: {
                Image(systemName: "repeat")
                    .foregroundStyle(controller.loopEnabled ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.borderless)
            .help(controller.loopEnabled ? "关闭循环" : "开启循环")
            .frame(width: 26)
        }
    }

    private func icon(_ system: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
        }
        .buttonStyle(.borderless)
        .help(help)
        .frame(width: 26)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(asset.fileName)
                .font(.headline)
                .lineLimit(2)
                .help(asset.fileName)

            VStack(spacing: 5) {
                infoRow("类型", asset.kind.name)
                infoRow("时间", recordedText)
                infoRow("地点", locationText)
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

    var body: some View {
        // 图标 + 文字横向排列，整组居中；两侧 Spacer 撑开实现居中
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            // 纯照片没有可截的帧，按钮不给出现（S 快捷键也随之失效）
            if asset.kind != .photo {
                ActionItem(title: "截取实况图", systemImage: "camera.shutter.button", keyEquivalent: "s") {
                    onGrab?()
                }
            }
            ActionItem(title: "在访达中显示", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: asset.filePath)])
            }
            ActionItem(title: asset.isFavorite ? "取消收藏" : "收藏",
                       systemImage: asset.isFavorite ? "heart.fill" : "heart",
                       tint: asset.isFavorite ? .pink : nil) {
                onToggleFavorite?()
            }
            ActionItem(title: "移到回收站", systemImage: "trash", tint: .red) {
                onDelete?()
            }
            Spacer(minLength: 0)
        }
    }
}

/// 功能区按钮：图标在上、文字在下，固定宽度保证四个一排时对齐
private struct ActionItem: View {
    let title: String
    let systemImage: String
    /// 传入才注册系统快捷键，避免抢走输入框里的按键
    var keyEquivalent: String?
    var tint: Color?
    let action: () -> Void

    @State private var hovering = false

    private var help: String {
        guard let k = keyEquivalent else { return title }
        return "\(title) (\(k.uppercased()))"
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
                    .minimumScaleFactor(0.8)   // 列被拖窄时允许文字缩小，不挤爆整排
            }
            .frame(width: 64, height: 46)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hovering ? Color.primary.opacity(0.10) : Color.primary.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
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
