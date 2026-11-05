import AVFoundation
import FCCore
import SwiftUI

/// 预览区：画面 + 播放控制。
struct PlayerPanel: View {
    @Bindable var model: EditorModel
    @Environment(\.displayScale) private var displayScale

    private var hasGrading: Bool { model.project.mainTrack.contains { !$0.filter.isIdentity } }

    private func reportSize(_ size: CGSize) {
        model.previewViewChanged(shortSidePixels: Double(min(size.width, size.height) * displayScale))
    }

    var body: some View {
        if let source = model.sourcePreview {
            // 换素材时重置播放器状态（@State 跟着视图身份走）
            SourcePreviewPanel(model: model, source: source)
                .id(source.url)
        } else {
            projectBody
        }
    }

    /// 工程时间线的常规预览（原内容）
    private var projectBody: some View {
        VStack(spacing: 0) {
            ZStack {
                // 预览区背景跟随主题外观（视频层自身透明，画面比例不足时
                // 露出的是主题色而不是黑边——亮色模式下不再是一块黑板）
                Theme.window
                if model.project.mainTrack.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "film.stack").font(.system(size: 36)).foregroundStyle(Theme.emptyHint)
                        Text("把视频或照片拖进来开始剪辑").foregroundStyle(Theme.secondary)
                        Button("导入素材…") { model.importPanel(addToTimeline: true) }
                            .buttonStyle(PanelButtonStyle(prominent: true))
                    }
                } else {
                    PlayerLayerView(player: model.player)
                        .aspectRatio(model.project.aspect.ratio, contentMode: .fit)
                        .overlay(alignment: .top) {
                            if let rec = model.recording { RecordingBadge(began: rec.began).padding(8) }
                        }
                        .overlay(alignment: .topLeading) {
                            if model.comparingOriginal {
                                Text("原图").font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.black.opacity(0.6), in: Capsule())
                                    .foregroundStyle(.white)
                                    .padding(8)
                            }
                        }
                        .overlay {
                            GeometryReader { g in
                                SubtitleOverlay(model: model, canvas: g.size)
                                TextOverlay(model: model, canvas: g.size)
                            }
                            .coordinateSpace(name: "subtitleCanvas")
                        }
                        // 预览渲染分辨率跟随画面实际大小（物理像素）
                        .background(GeometryReader { g in
                            Color.clear
                                .onAppear { reportSize(g.size) }
                                .onChange(of: g.size) { _, size in reportSize(size) }
                        })
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { model.togglePlay() }

            HStack(spacing: 18) {
                Text(model.playhead.displayString)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.accent)
                    .frame(width: 96, alignment: .trailing)
                Button { model.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                    .buttonStyle(.plain).help("上一帧 ←")
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .help("播放 / 暂停（空格）")
                Button { model.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                    .buttonStyle(.plain).help("下一帧 →")
                Text(model.duration.displayString)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 96, alignment: .leading)
            }
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .overlay(alignment: .trailing) {
                if hasGrading { CompareButton(model: model).padding(.trailing, 14) }
            }
            .disabled(model.duration == .zero)
        }
        .background(Theme.window)
    }
}

/// 按住显示原图，松开恢复调色效果。
private struct CompareButton: View {
    @Bindable var model: EditorModel

    var body: some View {
        Label("对比", systemImage: "square.split.2x1")
            .font(.system(size: 11))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(model.comparingOriginal ? Theme.accent.opacity(0.3) : Theme.raised, in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(model.comparingOriginal ? Theme.accent : Theme.secondary)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 1000, perform: {}, onPressingChanged: { pressing in
                model.comparingOriginal = pressing
            })
            .help("按住查看调色前的原图")
    }
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerNSView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        // 透明：视频画面比例不足时露出预览区的主题背景，而不是黑边
        layer?.backgroundColor = NSColor.clear.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

/// 资源池单击后的源素材预览：独立 AVPlayer（完全不打扰工程时间线 / 播放头），
/// 播放、暂停、拖进度。退出方式：× 按钮、点时间线片段、做任何工程编辑。
private struct SourcePreviewPanel: View {
    @Bindable var model: EditorModel
    let source: SourcePreviewRef

    @State private var player = AVPlayer()
    @State private var timeObserver: Any?
    @State private var isPlaying = false
    @State private var current: Double = 0
    @State private var total: Double = 0
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.window
                if source.isPlayable {
                    PlayerLayerView(player: player)
                } else if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { togglePlay() }
            .overlay(alignment: .top) { topBar.padding(10) }

            HStack(spacing: 14) {
                if source.isPlayable {
                    Button { togglePlay() } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .help("播放 / 暂停")
                    Slider(value: Binding(
                        get: { current },
                        set: { seek(to: $0) }
                    ), in: 0...max(total, 0.1))
                    .controlSize(.small)
                    Text("\(Self.timeString(current)) / \(Self.timeString(total))")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                } else {
                    Text("照片素材 · 点击时间线返回工程")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .foregroundStyle(Theme.text)
            .background(Theme.window)
        }
        .background(Theme.window)
        .onAppear { setup() }
        .onDisappear { teardown() }
        // 点时间线任意片段 → 退回工程预览
        .onChange(of: model.selection) { _, _ in
            model.sourcePreview = nil
        }
    }

    // MARK: 顶部信息条

    private var topBar: some View {
        HStack(spacing: 8) {
            Label("素材预览", systemImage: "eye")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(source.name)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                model.sourcePreview = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help("退出素材预览（点时间线片段也可以）")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
        .frame(maxWidth: 460)
    }

    // MARK: 播放器生命周期

    private func setup() {
        if source.isPlayable {
            player.actionAtItemEnd = .pause
            let item = AVPlayerItem(url: source.url)
            item.audioTimePitchAlgorithm = .spectral
            player.replaceCurrentItem(with: item)
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 30), queue: .main
            ) { t in
                MainActor.assumeIsolated {
                    current = CMTimeGetSeconds(t)
                    let d = CMTimeGetSeconds(player.currentItem?.duration ?? .zero)
                    if d.isFinite, d > 0 { total = d }
                    if player.rate == 0 { isPlaying = false }
                }
            }
        } else {
            image = NSImage(contentsOf: source.url)
        }
    }

    private func teardown() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func togglePlay() {
        guard source.isPlayable, player.currentItem != nil else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if total > 0, current >= total - 0.05 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    private func seek(to t: Double) {
        let target = min(max(t, 0), max(total, 0))
        current = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    private static func timeString(_ s: Double) -> String {
        let t = Int(max(s, 0).rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
