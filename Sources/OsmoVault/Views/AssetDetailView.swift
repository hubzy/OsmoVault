import SwiftUI
import AVFoundation

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

struct AssetDetailView: View {
    let asset: Asset
    /// 故意不用 @ObservedObject：时间变化只应重绘控制条和画面，不该每 0.25s 重排整个面板
    let controller: PlayerController
    var onRate: ((Int64, Int) -> Void)?
    var onColor: ((Int64, Int) -> Void)?
    var onToggleFavorite: (() -> Void)?
    var onGrab: (() -> Void)?

    /// 播放器还没报告真实尺寸时，先用素材库里记录的宽高兜底
    private var fallbackRatio: CGFloat {
        let w = CGFloat(asset.width), h = CGFloat(asset.height)
        guard w > 0, h > 0 else { return 16.0 / 9.0 }
        return w / h
    }

    var body: some View {
        VStack(spacing: 0) {
            PlayerStage(controller: controller, fallbackRatio: fallbackRatio)
                .frame(minHeight: 200)

            TransportBar(controller: controller, onGrab: onGrab)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            metadataBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    private var metadataBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(asset.fileName).font(.headline).lineLimit(1)
                Button {
                    onToggleFavorite?()
                } label: {
                    Image(systemName: asset.isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(asset.isFavorite ? .pink : .secondary)
                }
                .buttonStyle(.borderless)
                .help(asset.isFavorite ? "取消收藏" : "收藏")
                Spacer()
            }
            HStack(spacing: 14) {
                RatingControl(rating: asset.rating, onChange: { onRate?(asset.id ?? 0, $0) })
                ColorLabelControl(label: asset.colorLabel, onChange: { onColor?(asset.id ?? 0, $0) })
                Spacer()
            }
            HStack(spacing: 12) {
                if let t = asset.recordedAt { Label(t.formatted(), systemImage: "calendar") }
                if let lat = asset.latitude, let lon = asset.longitude {
                    Label(asset.placeName ?? String(format: "%.4f, %.4f", lat, lon), systemImage: "mappin.and.ellipse")
                }
                if asset.width > 0 { Label("\(asset.width)×\(asset.height)", systemImage: "photo") }
                if asset.frameRate > 0 { Label(String(format: "%.0f fps", asset.frameRate), systemImage: "speedometer") }
                if asset.srtPath != nil { Label("SRT", systemImage: "doc.text") }
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

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

/// 控制条：进度 + 逐帧 + 倍速 + 音量 + 循环 + 截帧
private struct TransportBar: View {
    @ObservedObject var controller: PlayerController
    var onGrab: (() -> Void)?

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

            icon("camera.shutter.button", "截取实况图 (S)") { onGrab?() }
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
