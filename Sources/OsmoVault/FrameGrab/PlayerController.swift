import AVFoundation
import Combine

@MainActor
final class PlayerController: ObservableObject {
    let player = AVPlayer()
    @Published var currentTime: Double = 0
    private var timeObserver: Any?

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            self?.currentTime = CMTimeGetSeconds(time)
        }
    }

    func load(url: URL) {
        let path = (player.currentItem?.asset as? AVURLAsset)?.url.path
        if path != url.path {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.play()
        }
    }

    deinit {
        if let o = timeObserver { player.removeTimeObserver(o) }
    }
}

