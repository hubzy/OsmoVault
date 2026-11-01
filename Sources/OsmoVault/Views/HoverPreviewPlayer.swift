import SwiftUI
import AVFoundation

/// NSView 封装 AVPlayerLayer，用于网格 hover 时的静音预览
final class HoverPreviewNSView: NSView {
    override func makeBackingLayer() -> CALayer {
        let l = AVPlayerLayer()
        l.videoGravity = .resizeAspect
        l.backgroundColor = NSColor.clear.cgColor
        return l
    }
    var playerLayer: AVPlayerLayer { (layer as? AVPlayerLayer) ?? AVPlayerLayer() }
    private var player: AVPlayer?

    func play(url: URL) {
        stop()
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        player = p
        playerLayer.videoGravity = .resizeAspect
        // 等首帧就绪再挂载，避免先渲染黑帧
        var observer: Any?
        observer = item.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
            guard let item, item.status == .readyToPlay else { return }
            DispatchQueue.main.async {
                self?.playerLayer.player = p
                p.play()
            }
            if let o = observer { NotificationCenter.default.removeObserver(o) }
        }
        p.play()
        // 循环播放
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak p] _ in
            p?.seek(to: .zero)
            p?.play()
        }
    }

    func stop() {
        player?.pause()
        playerLayer.player = nil
        player = nil
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

struct HoverPreviewPlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> HoverPreviewNSView {
        let v = HoverPreviewNSView()
        v.wantsLayer = true
        v.play(url: url)
        return v
    }

    func updateNSView(_ nsView: HoverPreviewNSView, context: Context) {}
    static func dismantleNSView(_ nsView: HoverPreviewNSView, coordinator: ()) {
        nsView.stop()
    }
}

