import SwiftUI
import AVFoundation

/// NSView 封装 AVPlayerLayer，用于网格 hover 时的静音预览
final class HoverPreviewNSView: NSView {
    override func makeBackingLayer() -> CALayer {
        let l = AVPlayerLayer()
        l.videoGravity = .resizeAspectFill
        l.backgroundColor = NSColor.clear.cgColor
        return l
    }

    private var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
    private var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    func play(url: URL) {
        stop()

        let item = AVPlayerItem(url: url)
        // 预览只需要"看个大概"，限制解码分辨率是降低 4K/5K 素材 CPU 占用最有效的一招
        item.preferredMaximumResolution = CGSize(width: 640, height: 640)
        item.preferredForwardBufferDuration = 0.5

        let p = AVPlayer(playerItem: item)
        p.volume = 0
        // hover 预览要的是立刻出画面，别为了防卡顿而憋着不播
        p.automaticallyWaitsToMinimizeStalling = false
        player = p

        // 等首帧就绪再挂载，避免先渲染黑帧
        statusObservation = item.observe(\.status, options: [.new]) { [weak self, weak p] item, _ in
            guard item.status == .readyToPlay, let p else { return }
            DispatchQueue.main.async { [weak self] in
                self?.playerLayer?.player = p
                p.play()
            }
        }

        // 循环播放
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak p] _ in
            p?.seek(to: .zero)
            p?.play()
        }
    }

    func stop() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let o = endObserver {
            NotificationCenter.default.removeObserver(o)
            endObserver = nil
        }
        player?.pause()
        playerLayer?.player = nil
        player = nil
    }

    override func layout() {
        super.layout()
        playerLayer?.frame = bounds
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
