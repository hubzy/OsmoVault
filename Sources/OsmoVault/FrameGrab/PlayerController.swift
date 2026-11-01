import AVFoundation
import Combine

@MainActor
final class PlayerController: ObservableObject {
    let player = AVPlayer()

    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var isReady = false
    /// 真实显示宽高比（presentationSize 已考虑旋转元数据），用于横竖屏自适应
    @Published var videoRatio: CGFloat?
    @Published var volumeLevel: Double = 1
    @Published var isMuted = false
    @Published var playbackRate: Float = 1
    @Published var loopEnabled = true

    /// 拖动进度条时暂停时间回调回写，避免滑块跟手打架
    var isScrubbing = false

    static let rateOptions: [Float] = [0.25, 0.5, 1, 1.5, 2]

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private var loadedPath: String?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        // 0.25s 回调一次即可：0.1s 会让控制条每秒重绘 10 次，纯属浪费主线程
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.isScrubbing else { return }
                self.currentTime = CMTimeGetSeconds(time)
            }
        }
    }

    /// 切到照片 / 没有可播内容时调用：彻底卸掉当前 item。
    /// 只 pause 不够 —— 留在 player 里的旧 item 会让"照片 → 同一条视频"因为
    /// `loadedPath` 相同被 `load` 提前 return，画面停在暂停状态不重新起播
    func unload() {
        teardownItemObservers()
        pause()
        loadedPath = nil
        isReady = false
        duration = 0
        currentTime = 0
        videoRatio = nil
        player.replaceCurrentItem(with: nil)
    }

    func load(url: URL) {
        guard loadedPath != url.path else { return }
        loadedPath = url.path

        teardownItemObservers()
        sizeObservation?.invalidate()
        pause()
        isReady = false
        duration = 0
        currentTime = 0
        videoRatio = nil

        let item = AVPlayerItem(url: url)
        // 本地文件不需要攒大缓冲：1s 足够，起播更快、内存占用更低
        item.preferredForwardBufferDuration = 1
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)

        // presentationSize 有时在 readyToPlay 那一刻还是 zero，竖屏就会套用错误的兜底比例，
        // 所以单独观察它，等真实尺寸到了再刷新（决定横屏还是竖屏布局）
        sizeObservation = item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                let size = item.presentationSize
                guard size.width > 1, size.height > 1 else { return }
                self?.videoRatio = size.width / size.height
            }
        }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    let d = CMTimeGetSeconds(item.duration)
                    self.duration = d.isFinite ? d : 0
                    // presentationSize 是"显示尺寸"，已把旋转矩阵算进去，比读素材宽高可靠
                    let size = item.presentationSize
                    if size.width > 1, size.height > 1 {
                        self.videoRatio = size.width / size.height
                    }
                    self.isReady = true
                    self.player.rate = self.playbackRate
                    self.isPlaying = true
                case .failed:
                    self.isReady = false
                    self.isPlaying = false
                default:
                    break
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.loopEnabled else {
                    self.isPlaying = false
                    return
                }
                self.player.seek(to: .zero)
                self.player.rate = self.playbackRate
            }
        }
    }

    // MARK: - 播放控制

    func togglePlay() {
        if player.rate == 0 {
            player.rate = playbackRate
            isPlaying = true
        } else {
            player.rate = 0
            isPlaying = false
        }
    }

    func pause() {
        player.rate = 0
        isPlaying = false
    }

    /// 从头播放（实况照片用）
    func playFromStart() {
        seek(to: 0)
        player.rate = playbackRate
        isPlaying = true
    }

    /// 拖动结束时调用：真正跳转
    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), max(duration, 0))
        let t = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isScrubbing = false
                self.currentTime = clamped
            }
        }
    }

    func seek(by delta: Double) {
        seek(to: currentTime + delta)
    }

    /// 逐帧步进，挑帧截实时用；会先暂停
    func step(frames: Int) {
        pause()
        player.currentItem?.step(byCount: frames)
        currentTime = CMTimeGetSeconds(player.currentTime())
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying { player.rate = rate }
    }

    func setVolume(_ value: Double) {
        volumeLevel = value
        isMuted = value == 0
        player.isMuted = isMuted
        player.volume = Float(value)
    }

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
        if !isMuted, volumeLevel == 0 {
            volumeLevel = 0.6
            player.volume = 0.6
        }
    }

    var volumeIcon: String {
        if isMuted || volumeLevel == 0 { return "speaker.slash.fill" }
        if volumeLevel < 0.34 { return "speaker.fill" }
        if volumeLevel < 0.67 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    private func teardownItemObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        sizeObservation?.invalidate()
        sizeObservation = nil
        if let o = endObserver {
            NotificationCenter.default.removeObserver(o)
            endObserver = nil
        }
    }

    deinit {
        if let o = timeObserver { player.removeTimeObserver(o) }
    }
}
