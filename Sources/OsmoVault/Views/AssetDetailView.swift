import SwiftUI
import AVFoundation

/// AVPlayerLayer 视图，替代 AVKit VideoPlayer（后者在 CommandLineTools 工具链下会崩溃）
struct LayerPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerNSView {
        let v = PlayerLayerNSView()
        v.wantsLayer = true
        v.configure(player: player)
        return v
    }

    func updateNSView(_ nsView: PlayerLayerNSView, context: Context) {}
}

final class PlayerLayerNSView: NSView {
    private var addedLayer: AVPlayerLayer?

    func configure(player: AVPlayer) {
        guard addedLayer == nil else { return }
        let l = AVPlayerLayer(player: player)
        l.videoGravity = .resizeAspect
        l.frame = bounds
        l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        wantsLayer = true
        layer?.addSublayer(l)
        addedLayer = l
    }

    override func layout() {
        super.layout()
        addedLayer?.frame = bounds
    }
}

struct AssetDetailView: View {
    let asset: Asset
    @ObservedObject var controller: PlayerController
    var onRate: ((Int64, Int) -> Void)?
    var onColor: ((Int64, Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LayerPlayerView(player: controller.player)
                .aspectRatio(16/9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text(asset.fileName).font(.headline)
                HStack(spacing: 16) {
                    RatingControl(rating: asset.rating, onChange: { onRate?(asset.id ?? 0, $0) })
                    ColorLabelControl(label: asset.colorLabel, onChange: { onColor?(asset.id ?? 0, $0) })
                }
                HStack(spacing: 16) {
                    if let t = asset.recordedAt { Label(t.formatted(), systemImage: "calendar") }
                    if let lat = asset.latitude, let lon = asset.longitude {
                        Label(asset.placeName ?? String(format: "%.4f, %.4f", lat, lon), systemImage: "mappin.and.ellipse")
                    }
                    if asset.width > 0 { Label("\(asset.width)×\(asset.height)", systemImage: "photo") }
                    if asset.frameRate > 0 { Label(String(format: "%.0ffps", asset.frameRate), systemImage: "speedometer") }
                }
                .font(.caption).foregroundStyle(.secondary)
                Text(String(format: "当前时间 %.2fs（按 S 截取此帧）", controller.currentTime))
                    .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                if asset.srtPath != nil {
                    Label("已关联 SRT 遥测", systemImage: "doc.text")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 12)
        .onAppear { controller.load(url: URL(fileURLWithPath: asset.filePath)) }
    }
}

