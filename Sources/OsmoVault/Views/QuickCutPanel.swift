import SwiftUI
import AppKit
import AVFoundation

/// 一键出片页（三列布局）：
///   左列  素材池（缩略图网格）—— 与片段列表并排，中间分隔条可拖动调节宽度
///   中列  片段顺序（起止/排序/跳段）
///   右列  上方预览大画面，下方进度条 + 播放控制（功能操作）
///   底部  导出设置（画幅/转场/BGM）+ 导出按钮
///
/// 「预览即所得」：预览画面来自 `QuickCutService.prepare` 的 composition，
/// 导出走同一条 prepare + 导出会话，转场/画幅/BGM 效果所见即所得。
struct QuickCutPanel: View {
    @EnvironmentObject var appModel: AppModel

    @StateObject private var preview = QuickCutPreviewController()

    /// 素材池里勾选的素材；为空表示"用全部"
    @State private var pickedIDs: Set<Int64> = []
    @State private var segments: [CutSegment] = []
    @State private var isExporting = false
    @State private var status: String?
    @State private var outputURL: URL?
    @State private var bgmURL: URL?
    @State private var showBGMImporter = false
    @State private var progressValue: Double = 0
    @State private var transitionSeconds: Double = 0
    @State private var confirmClearSegments = false
    @State private var aspect: QuickCutConfig.Aspect = .original
    @State private var clipSeconds: Double = 6
    @State private var onlyHighRated = false

    /// 上一次构建成功的预览时间线；配置变化后 computed 的 `previewDirty` 变 true，需点刷新
    @State private var prepared: PreparedTimeline?
    @State private var builtSignature: Signature?
    @State private var isPreparingPreview = false
    @State private var previewError: String?

    private var poolColumns: [GridItem] { [GridItem(.adaptive(minimum: 88), spacing: 8)] }

    // MARK: - 主体

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            autoBar
            HSplitView {
                poolColumn
                    .frame(minWidth: 250, idealWidth: 320, maxWidth: 420)
                rightColumn
                    .frame(minWidth: 560, maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
            Divider()
            settingsBar
        }
        .padding(16)
        .frame(minWidth: 860)
        .background(FileImporter(isPresented: $showBGMImporter, bgmURL: $bgmURL))
        // 预览过期用「配置签名」对比判定：segments / 转场 / 画幅 / BGM 任一变化，
        // body 重算时 previewDirty 自动变 true（派生值，无需 onChange 手动标记）
        .onDisappear { preview.unload() }
        // 手调过的起止时间不可一键重建，清空前必须确认
        .confirmationDialog("清空片段？", isPresented: $confirmClearSegments) {
            Button("清空 \(segments.count) 段", role: .destructive) {
                segments.removeAll()
                clearPreview()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("手动调整过的起止时间不会保留，清空后需要重新「自动出片」生成")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("一键出片").font(.title2).bold()
            Text("勾选素材 → 自动出片 → 微调片段 → 预览确认 → 导出。右侧预览与导出效果完全一致。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 顶部操作行：自动出片 + 参数 + 清空
    private var autoBar: some View {
        HStack(spacing: 10) {
            Button {
                autoBuild()
            } label: {
                Label("自动出片", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .disabled(poolAssets.isEmpty)

            Stepper(value: $clipSeconds, in: 1...60, step: 1) {
                Text("每段 \(Int(clipSeconds))s").font(.caption).monospacedDigit()
            }
            .frame(width: 118)

            Toggle("仅高评分", isOn: $onlyHighRated)
                .font(.caption)
                .help("只从评分 ≥ 4 的素材里选片段")

            Spacer(minLength: 0)

            Button("清空片段", role: .destructive) { confirmClearSegments = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(segments.isEmpty)
        }
    }

    // MARK: - 左列：素材池

    private var poolColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("素材池").font(.headline)
                Text(pickedIDs.isEmpty ? "用全部 \(videoAssets.count)" : "已选 \(pickedIDs.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !pickedIDs.isEmpty {
                    Button("取消勾选") { pickedIDs.removeAll() }.font(.caption)
                }
            }
            ScrollView {
                LazyVGrid(columns: poolColumns, spacing: 8) {
                    ForEach(videoAssets) { asset in
                        poolCell(asset)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func poolCell(_ asset: Asset) -> some View {
        let id = asset.id ?? 0
        let picked = pickedIDs.contains(id)
        return Button {
            if picked { pickedIDs.remove(id) } else { pickedIDs.insert(id) }
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    AsyncThumbView(asset: asset)
                        .frame(height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .frame(maxWidth: .infinity)
                    if asset.rating >= 4 {
                        Image(systemName: "star.fill")
                            .font(.caption2).foregroundStyle(.yellow)
                            .padding(3)
                    }
                }
                Text(asset.fileName)
                    .font(.caption2).lineLimit(1)
                Text(String(format: "%.0fs", asset.durationSeconds))
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(picked ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 片段顺序面板（预览进度条下方，高度随窗口在 150~290 之间伸缩）

    private var segmentPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("片段顺序").font(.headline)
                Text("\(segments.count) 段 · \(Self.timeText(totalSeconds))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
            }
            if segments.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text("点「自动出片」一键生成，或在素材池里勾选后重新生成")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.gray.opacity(0.07))
                )
            } else {
                List {
                    ForEach($segments) { $seg in
                        segmentRow($seg)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minHeight: 150, maxHeight: 290)
    }

    private func segmentRow(_ seg: Binding<CutSegment>) -> some View {
        let index = segments.firstIndex { $0.id == seg.wrappedValue.id } ?? 0
        return HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(seg.wrappedValue.fileName).font(.caption).lineLimit(1)
                HStack(spacing: 5) {
                    Text("起").font(.caption2).foregroundStyle(.secondary)
                    TextField("", value: seg.start, format: .number)
                        .frame(width: 44).controlSize(.mini)
                    Text("止").font(.caption2).foregroundStyle(.secondary)
                    TextField("", value: seg.end, format: .number)
                        .frame(width: 44).controlSize(.mini)
                    Text(String(format: "%.1fs", seg.wrappedValue.duration))
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            VaultIconButton("预览中跳到此片段", systemImage: "arrow.right.to.line", hit: 24,
                            isDisabled: !canJumpToSegment(index)) {
                jumpToSegment(index)
            }
            VaultIconButton("上移片段", systemImage: "arrow.up", hit: 24,
                            isDisabled: index == 0) { move(index, by: -1) }
            VaultIconButton("下移片段", systemImage: "arrow.down", hit: 24,
                            isDisabled: index == segments.count - 1) { move(index, by: 1) }
            VaultIconButton("移除片段", systemImage: "xmark.circle", hit: 24) {
                segments.remove(at: index)
                if segments.isEmpty { clearPreview() }
            }
        }
    }

    // MARK: - 右侧：预览 + 功能操作 + 片段顺序

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("预览").font(.headline)
                if let t = prepared, !previewDirty {
                    Text("总长 \(Self.timeText(CMTimeGetSeconds(t.total)))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                if !segments.isEmpty, !isPreparingPreview {
                    if previewDirty {
                        Label("设置已改", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button {
                        refreshPreview()
                    } label: {
                        Label(prepared == nil ? "生成预览" : "刷新预览", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!previewDirty)
                    .help("按当前片段与设置为预览生成时间线")
                }
            }
            videoStage
            previewBar
            segmentPanel
        }
    }

    private var videoStage: some View {
        ZStack {
            Vault.shape(Vault.R.container)
                .fill(Color.gray.opacity(0.07))
            Vault.shape(Vault.R.container)
                .strokeBorder(Color.gray.opacity(0.18), lineWidth: 1)
                .allowsHitTesting(false)   // 必修：1px 装饰描边不参与命中

            if segments.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text("先「自动出片」生成片段，这里就能预览拼接效果")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if isPreparingPreview {
                ProgressView("正在生成预览…").controlSize(.small)
            } else if let t = prepared, preview.isReady {
                QuickCutPlayerStage(player: preview.player)
                    .clipShape(Vault.shape(Vault.R.container))
                    .aspectRatio(t.renderRatio, contentMode: .fit)
                    .padding(2)
            } else if let err = previewError {
                VStack(spacing: 6) {
                    Text("预览生成失败").font(.caption)
                    Text(err).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    Button("重试", action: refreshPreview).controlSize(.small)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "play.rectangle.on.rectangle").foregroundStyle(.tertiary)
                    Text("点「\(prepared == nil ? "生成预览" : "刷新预览")」查看拼接效果")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 170)
        .contentShape(Vault.shape(Vault.R.container))
    }

    /// 功能操作区：进度条 + 时间 + 播放/从头/静音
    private var previewBar: some View {
        HStack(spacing: 6) {
            Text(Self.timeText(preview.currentTime))
                .font(.caption2.monospacedDigit())
                .frame(width: 34, alignment: .trailing)
            Slider(
                value: Binding(
                    get: { preview.currentTime },
                    set: { preview.currentTime = $0 }
                ),
                in: 0...max(preview.duration, 0.1)
            ) { editing in
                preview.isScrubbing = editing
                // 松手才真正 seek，拖动过程中不打断播放
                if !editing { preview.seek(to: preview.currentTime) }
            }
            .disabled(!preview.isReady || preview.duration <= 0)
            Text(Self.timeText(preview.duration))
                .font(.caption2.monospacedDigit())
                .frame(width: 34, alignment: .leading)
            VaultIconButton(preview.isPlaying ? "暂停" : "播放",
                            systemImage: preview.isPlaying ? "pause.fill" : "play.fill",
                            symbolSize: 15, hit: 28,
                            isDisabled: !preview.isReady) {
                preview.togglePlay()
            }
            VaultIconButton("从头播放", systemImage: "backward.end.fill", symbolSize: 14, hit: 28,
                            isDisabled: !preview.isReady) {
                preview.playFromStart()
            }
            VaultIconButton(preview.isMuted ? "取消静音" : "静音",
                            systemImage: preview.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            symbolSize: 13, hit: 28,
                            isDisabled: !preview.isReady) {
                preview.toggleMute()
            }
        }
    }

    // MARK: - 底部导出设置 + 导出

    private var settingsBar: some View {
        HStack(spacing: 12) {
            Picker("画幅", selection: $aspect) {
                ForEach(QuickCutConfig.Aspect.allCases) { a in
                    Text(a.rawValue).tag(a)
                }
            }
            .frame(width: 108)

            HStack(spacing: 6) {
                Text("转场").font(.caption)
                Slider(value: $transitionSeconds, in: 0...2, step: 0.1).frame(width: 96)
                Text(transitionSeconds == 0 ? "硬切" : String(format: "%.1fs 溶解", transitionSeconds))
                    .font(.caption).monospacedDigit()
                    .frame(width: 74, alignment: .leading)
            }

            Toggle("背景音乐", isOn: Binding(
                get: { bgmURL != nil },
                set: { on in if !on { bgmURL = nil } }
            ))
            .font(.caption)
            Button(bgmURL == nil ? "选择音乐…" : bgmURL!.lastPathComponent) {
                showBGMImporter = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(bgmURL != nil)
            .lineLimit(1)
            .frame(maxWidth: 170)
            if bgmURL != nil {
                Button {
                    bgmURL = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("移除所选音乐")
            }

            Spacer(minLength: 0)

            Button {
                exportAll()
            } label: {
                if isExporting { ProgressView().controlSize(.small) }
                Text(isExporting ? "导出中…" : "导出 mp4")
            }
            .buttonStyle(.borderedProminent)
            .disabled(segments.isEmpty || isExporting)
            .help(previewDirty ? "预览配置已过期，但导出仍按当前最新设置生成" : "按当前预览效果导出")

            if isExporting {
                ProgressView(value: progressValue).frame(width: 130)
                Text(String(format: "%.0f%%", progressValue * 100))
                    .font(.caption).monospacedDigit()
            }
            if let s = status {
                Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(s)
            }
            if outputURL != nil, !isExporting {
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL!])
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - 数据

    /// 出片只接视频；照片/实况进不了时间线（要做成片段得先转码，暂不支持）
    private var videoAssets: [Asset] {
        appModel.assets.filter { $0.kind == .video }
    }

    private var poolAssets: [Asset] {
        let base = pickedIDs.isEmpty
            ? videoAssets
            : videoAssets.filter { pickedIDs.contains($0.id ?? 0) }
        let filtered = onlyHighRated ? base.filter { $0.rating >= 4 } : base
        return filtered.sorted { ($0.recordedAt ?? .distantPast) < ($1.recordedAt ?? .distantPast) }
    }

    private var totalSeconds: Double {
        guard !segments.isEmpty else { return 0 }
        let raw = segments.reduce(0) { $0 + $1.duration }
        let overlap = segments.count > 1 ? transitionSeconds * Double(segments.count - 1) : 0
        return max(raw - overlap, 0)
    }

    /// 当前配置的签名：任何会影响时间线的设置都在这里，变了就说明预览过期
    private var configSignature: Signature {
        Signature(segments: segments, transition: transitionSeconds, aspect: aspect, bgmPath: bgmURL?.path)
    }

    private var previewDirty: Bool { builtSignature != configSignature }

    private func canJumpToSegment(_ index: Int) -> Bool {
        guard let t = prepared, !previewDirty, preview.isReady else { return false }
        return t.segmentStarts.indices.contains(index)
    }

    // MARK: - 逻辑

    private func makeConfig() -> QuickCutConfig {
        var cfg = QuickCutConfig()
        cfg.transitionDuration = transitionSeconds
        cfg.aspect = aspect
        if let bgm = bgmURL { cfg.includeBGM = true; cfg.bgmPath = bgm.path }
        return cfg
    }

    private func autoBuild() {
        let pool = poolAssets
        guard !pool.isEmpty else { status = "没有可用素材"; return }
        segments = pool.prefix(40).map { a in
            let dur = min(clipSeconds, max(a.durationSeconds, 0.5))
            // 从 20% 处开始取，跳过无人机起飞/开机的废镜头
            let start = min(a.durationSeconds * 0.2, max(a.durationSeconds - dur, 0))
            return CutSegment(assetID: a.id ?? 0, sourcePath: a.filePath, fileName: a.fileName,
                              start: start, end: start + dur)
        }
        status = "已生成 \(segments.count) 段"
        previewError = nil
        refreshPreview()
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard segments.indices.contains(target) else { return }
        segments.swapAt(index, target)
    }

    private func jumpToSegment(_ index: Int) {
        guard let t = prepared, !previewDirty, t.segmentStarts.indices.contains(index) else { return }
        preview.seek(to: CMTimeGetSeconds(t.segmentStarts[index]))
    }

    /// 按当前片段与设置重建预览时间线（与导出共用 prepare，效果一定一致）
    private func refreshPreview() {
        guard !segments.isEmpty else { clearPreview(); return }
        isPreparingPreview = true
        previewError = nil
        Task { @MainActor in
            defer { isPreparingPreview = false }
            do {
                let timeline = try QuickCutService.prepare(segments: segments, config: makeConfig())
                guard !Task.isCancelled else { return }
                prepared = timeline
                builtSignature = configSignature
                preview.load(timeline)
            } catch {
                previewError = error.localizedDescription
                preview.unload()
            }
        }
    }

    private func clearPreview() {
        preview.unload()
        prepared = nil
        builtSignature = nil
    }

    private func exportAll() {
        isExporting = true
        status = nil
        outputURL = nil
        progressValue = 0
        Task {
            do {
                let out = QuickCutService.defaultOutputURL()
                try await QuickCutService.export(segments: segments, config: makeConfig(), to: out) { p in
                    Task { @MainActor in progressValue = p }
                }
                outputURL = out
                status = "已导出：\(out.lastPathComponent)"
            } catch {
                status = "失败：\(error.localizedDescription)"
            }
            isExporting = false
        }
    }

    // MARK: - 配置签名

    private struct Signature: Equatable {
        let segments: [CutSegment]
        let transition: Double
        let aspect: QuickCutConfig.Aspect
        let bgmPath: String?
    }

    static func timeText(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}

// MARK: - 预览播放控制器

/// 预览专用播放器：只管一条 composition 时间线（转场/画幅/BGM 都由 videoComposition 呈现），
/// 播完停在结尾等待用户从头/跳段，不需要倍速、逐帧那套。
@MainActor
final class QuickCutPreviewController: ObservableObject {
    let player = AVPlayer()

    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var isReady = false
    @Published var isMuted = false

    /// 拖动进度条时暂停时间回调回写，避免滑块跟手打架
    var isScrubbing = false

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        // 0.25s 回调一次即可：控制条不需要每秒重绘 10 次
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.isScrubbing else { return }
                self.currentTime = CMTimeGetSeconds(time)
            }
        }
    }

    /// 加载一条已构建好的时间线（与导出共用 `QuickCutService.prepare` 产物）
    func load(_ timeline: PreparedTimeline) {
        teardownItemObservers()
        player.rate = 0
        isReady = false
        isPlaying = false
        duration = 0
        currentTime = 0

        let item = AVPlayerItem(asset: timeline.composition)
        item.videoComposition = timeline.videoComposition
        item.audioMix = timeline.audioMix
        item.preferredForwardBufferDuration = 1
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                guard item.status == .readyToPlay else { return }
                let d = CMTimeGetSeconds(item.duration)
                self.duration = d.isFinite ? d : 0
                self.isReady = true
            }
        }
        // 预览播完停在结尾，不循环
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
            }
        }
    }

    // MARK: - 播放控制

    func togglePlay() {
        guard isReady else { return }
        if player.rate == 0 {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    func playFromStart() {
        guard isReady else { return }
        seek(to: 0)
        player.play()
        isPlaying = true
    }

    /// 拖动结束时调用：真正跳转
    func seek(to seconds: Double) {
        let t = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isScrubbing = false
                self.currentTime = max(seconds, 0)
            }
        }
    }

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    /// 卸载：页面消失时兜底停声，也释放旧时间线占用的资源
    func unload() {
        teardownItemObservers()
        player.rate = 0
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        isReady = false
        isMuted = false
        duration = 0
        currentTime = 0
    }

    private func teardownItemObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let o = endObserver {
            NotificationCenter.default.removeObserver(o)
            endObserver = nil
        }
    }

    deinit {
        if let o = timeObserver { player.removeTimeObserver(o) }
    }
}

// MARK: - 预览画面层

/// AVPlayerLayer 直接做 backing layer（与详情页同一思路，CommandLineTools 工具链下 AVKit 不可靠）
private struct QuickCutPlayerStage: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> QuickCutPlayerLayerView {
        let v = QuickCutPlayerLayerView(frame: .zero)
        v.player = player
        return v
    }

    func updateNSView(_ nsView: QuickCutPlayerLayerView, context: Context) {
        nsView.player = player
    }
}

private final class QuickCutPlayerLayerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let l = AVPlayerLayer()
        l.videoGravity = .resizeAspect
        // 画面外的信箱区透出容器淡灰底色，不硬编码黑色
        l.backgroundColor = nil
        layer = l
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    var player: AVPlayer? {
        get { (layer as? AVPlayerLayer)?.player }
        set { (layer as? AVPlayerLayer)?.player = newValue }
    }

    override func layout() {
        super.layout()
        (layer as? AVPlayerLayer)?.frame = bounds
    }
}
