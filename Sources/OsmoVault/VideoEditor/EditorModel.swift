import AppKit
import AVFoundation
import FCCore
import FCEngine
import FCMedia
import Observation
import UniformTypeIdentifiers

enum Selection: Equatable {
    case video(UUID)
    case music(UUID)
    case subtitle(UUID)
    case text(UUID)
    /// 人声区间（避让）。
    case duck(UUID)
    /// 转场，以其后的片段 id 标识。
    case transition(UUID)
}

enum ExportState: Equatable {
    case idle
    case running(Double)
    case done(URL)
    case failed(String)
}

/// 资源池单击后临时在预览区播放的源素材。
/// 预览区用它时显示独立的源播放器（播放 / 拖进度），
/// 点时间线片段、做任何工程编辑或点 × 退出。
struct SourcePreviewRef: Equatable {
    let url: URL
    let name: String
    /// 视频 / 实况照片（动态部分）用播放器；照片静态显示。
    let isPlayable: Bool
}

/// 一个打开的工程：编辑状态、播放器、自动保存、导出与识别。
@Observable
@MainActor
final class EditorModel {
    static let autosaveDelay: UInt64 = 2_000_000_000

    let store: EditorStore
    let packageURL: URL
    let player = AVPlayer()

    var playhead: Time = .zero
    var isPlaying = false
    var selection: Selection?
    /// 时间线缩放：每秒多少点。
    var pointsPerSecond: Double = 60
    private(set) var layout: TimelineLayout
    private(set) var duration: Time = .zero
    var missingAssets: [MediaAsset] = []
    var exportState: ExportState = .idle
    var showExport = false
    var errorMessage: String?
    /// 非错误的提示（如自动切换到 HDR）。
    var notice: String?
    var lastSaved: Date?
    var importing = false
    /// 资源池单击预览的源素材：非 nil 时预览区显示它而不是工程时间线。
    /// 视频走独立播放器；做任何工程编辑或点时间线片段时自动退出。
    var sourcePreview: SourcePreviewRef?

    var project: Project { store.project }

    @ObservationIgnored private var built: BuiltComposition?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var seekTarget: Time?
    @ObservationIgnored private var isSeeking = false

    init(project: Project, packageURL: URL) {
        store = EditorStore(project: project)
        self.packageURL = packageURL
        layout = TimelineLayout(project: project)
        player.actionAtItemEnd = .pause
        store.onChange = { [weak self] _ in self?.projectChanged() }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.playerTick(time) }
        }
        installKeyMonitor()
        checkMissingAssets()
        scheduleRebuild(immediate: true)
    }

    func close() {
        if recorder != nil { recorder?.stop(); recorder = nil }
        settleLiveText()
        save()
        trashUnusedRecordings()
        exportTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        timeObserver = nil
        keyMonitor = nil
    }

    // MARK: 变更

    private func projectChanged() {
        // 任何工程编辑都退出源素材预览，预览区回到时间线画面
        if sourcePreview != nil { sourcePreview = nil }
        // 只改文字 / 字幕样式时主轨布局没变：别惊动整条时间线重算
        let nextLayout = TimelineLayout(project: store.project)
        if nextLayout != layout { layout = nextLayout }
        validateSelection()
        scheduleRebuild()
        scheduleAutosave()
    }

    private func validateSelection() {
        switch selection {
        case .video(let id), .transition(let id):
            if project.mainClip(id: id) == nil { selection = nil }
        case .music(let id):
            if project.music(id: id) == nil { selection = nil }
        case .subtitle(let id):
            if project.subtitle(id: id) == nil { selection = nil }
        case .text(let id):
            if project.text(id: id) == nil { selection = nil }
        case .duck(let id):
            if !project.duckRanges.contains(where: { $0.id == id }) { selection = nil }
        case nil:
            break
        }
    }

    // MARK: 播放

    /// 预览渲染短边：跟随预览区实际像素，渲染跟不上时降档（上限 previewCap）。
    private(set) var previewShortSide = 720
    @ObservationIgnored private var previewViewPixels: Double = 720
    @ObservationIgnored private var previewCap = PreviewQuality.tiers.last!
    @ObservationIgnored private var qualityTask: Task<Void, Never>?

    var previewSize: CGSize { RenderSize.size(aspect: project.aspect, shortSide: previewShortSide) }

    /// 预览区尺寸变化（短边，物理像素）。
    func previewViewChanged(shortSidePixels: Double) {
        previewViewPixels = shortSidePixels
        applyPreviewQuality()
    }

    private func applyPreviewQuality() {
        let side = PreviewQuality.shortSide(viewPixels: previewViewPixels, cap: previewCap)
        guard side != previewShortSide else { return }
        previewShortSide = side
        scheduleRebuild()
    }

    /// 播放时每 2 秒检查渲染耗时，跟不上就降一档。
    private func startQualityMonitor() {
        RenderTimer.preview.reset()
        qualityTask?.cancel()
        qualityTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.isPlaying else { return }
                guard let avg = RenderTimer.preview.averageMs else { continue }
                let cap = PreviewQuality.capAfterMeasuring(cap: min(self.previewCap, self.previewShortSide),
                                                           averageRenderMs: avg, frameRate: self.project.frameRate)
                if cap < self.previewShortSide {
                    self.previewCap = cap
                    self.applyPreviewQuality()
                }
                RenderTimer.preview.reset()
            }
        }
    }

    /// 当前播放项创建时使用的输出动态范围。
    @ObservationIgnored private var itemOutput: DynamicRangeOutput = .sdr

    /// HDR 工程以 HLG 预览，在支持 EDR 的屏幕上显示真实亮度。
    var previewOutput: DynamicRangeOutput { project.colorMode == .hdr ? .hlg : .sdr }

    func scheduleRebuild(immediate: Bool = false) {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(nanoseconds: 120_000_000) }
            guard !Task.isCancelled else { return }
            await self?.rebuild()
        }
    }

    private func rebuild() async {
        let project = store.project
        let size = previewSize
        guard !layout.placements.isEmpty else {
            built = nil
            duration = .zero
            player.replaceCurrentItem(with: nil)
            isPlaying = false
            playhead = .zero
            return
        }
        let output = previewOutput
        if let built, let item = player.currentItem, built.canUpdateInPlace(project: project, from: itemOutput, to: output) {
            itemOutput = output
            item.videoComposition = built.makeVideoComposition(project: renderProject(project), renderSize: size, output: output)
            item.audioMix = built.makeAudioMix(project: project)
            if !isPlaying { seek(to: playhead) }
            return
        }
        do {
            let next = try await CompositionBuilder.build(project: project, renderSize: size)
            guard !Task.isCancelled, project == store.project else { return }
            let item = AVPlayerItem(asset: next.composition)
            item.videoComposition = next.makeVideoComposition(project: renderProject(project), renderSize: size, output: output)
            itemOutput = output
            item.audioMix = next.makeAudioMix(project: project)
            item.audioTimePitchAlgorithm = .spectral
            built = next
            duration = next.duration
            let wasPlaying = isPlaying
            player.replaceCurrentItem(with: item)
            seek(to: Time.min(playhead, duration))
            if wasPlaying { player.play() }
        } catch CompositionError.missingAsset {
            checkMissingAssets() // 由“重新定位”窗口提示，不再弹错误框
        } catch {
            errorMessage = error.localizedDescription
            Log.project.error("预览构建失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func playerTick(_ time: CMTime) {
        guard isPlaying else { return }
        playhead = Time(time)
        if player.rate == 0 {
            isPlaying = false
        }
    }

    func togglePlay() {
        // 源素材预览态时空格不驱动工程播放器（预览区此刻显示的不是时间线）
        guard sourcePreview == nil, duration > .zero else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if playhead >= duration - Time(seconds: 0.05) { seek(to: .zero) }
            player.play()
            isPlaying = true
            startQualityMonitor()
        }
    }

    /// 连续拖动时只保留最新目标，避免排队卡顿。
    func seek(to t: Time) {
        let target = t.clamped(.zero, duration)
        playhead = target
        seekTarget = target
        if !isSeeking { performSeek() }
    }

    private func performSeek() {
        guard let target = seekTarget, player.currentItem != nil else {
            isSeeking = false
            return
        }
        seekTarget = nil
        isSeeking = true
        player.seek(to: target.cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.isSeeking = false
                self?.performSeek()
            }
        }
    }

    func step(frames: Int) {
        if isPlaying { togglePlay() }
        seek(to: playhead + Time(seconds: Double(frames) / Double(project.frameRate)))
    }

    /// 缩放时保持在屏幕上不动的时刻（鼠标处或播放头），由时间线读取后清空。
    @ObservationIgnored var zoomAnchor: Time?
    /// 下次缩放后滚回开头（适应窗口用）。
    @ObservationIgnored var zoomScrollsToStart = false
    /// 时间线可视宽度，由时间线视图写入。
    @ObservationIgnored var timelineViewportWidth: Double = 800

    /// 菜单 / 滑块缩放：以播放头为锚点。
    func zoom(by factor: Double) {
        zoom(by: factor, anchor: playhead)
    }

    /// 适应窗口：整段时长铺满时间线并滚回开头。
    func zoomToFit() {
        zoomScrollsToStart = true
        pointsPerSecond = TimelineZoom.fit(duration: duration, viewportWidth: timelineViewportWidth, leading: 16, trailing: 60)
    }

    func zoom(by factor: Double, anchor: Time) {
        zoomAnchor = anchor
        pointsPerSecond = TimelineZoom.clamped(pointsPerSecond * factor)
    }

    // MARK: 编辑

    func splitAtPlayhead() {
        let t = playhead
        if case .subtitle(let id) = selection, let sub = project.subtitle(id: id), sub.start < t, t < sub.end {
            var newID: UUID?
            store.perform { newID = $0.splitSubtitle(id: id, at: t) }
            if let newID { selection = .subtitle(newID) }
            return
        }
        if case .music(let id) = selection, let clip = project.music(id: id), clip.start < t, t < clip.end {
            store.perform { _ = $0.splitMusic(id: id, at: t) }
            return
        }
        var newID: UUID?
        store.perform { newID = $0.splitMain(at: t) }
        if let newID { selection = .video(newID) }
    }

    /// 分离音频：原声放到音频轨并选中它，原片段静音。
    func detachAudio(_ id: UUID) {
        var newID: UUID?
        store.perform { newID = $0.detachAudio(id: id) }
        if let newID { selection = .music(newID) }
    }

    // MARK: 预览里原地编辑文字

    /// 预览画面上正在原地编辑的文字或字幕的 id。
    var previewEditing: UUID?

    /// 双击预览里的文字或字幕开始编辑：暂停播放，选中它，整次编辑合成一步撤销。
    func beginPreviewEditing(_ target: Selection, id: UUID) {
        endPreviewEditing()
        if isPlaying { togglePlay() }
        selection = target
        store.beginCoalescing()
        previewEditing = id
    }

    func endPreviewEditing() {
        guard previewEditing != nil else { return }
        previewEditing = nil
        store.endCoalescing()
    }

    // MARK: 预览里拖动文字（即时反馈）

    /// 正在拖动的文字。文字本来由 AVPlayer 通过 videoComposition 画进视频帧，改一次工程要等
    /// 120ms 去抖 → 重建全部合成指令 → 精确 seek 解码一帧才刷新，拖动时明显滞后。
    /// 拖动期间改由 SwiftUI 直接画同一张位图，视频层暂时不画它；松手后一次性提交并换回。
    struct LiveText: Equatable {
        var id: UUID
        var style: SubtitleStyle
        /// true：视频层跳过这条文字（拖动中）；false：视频层已恢复，副本只作过渡。
        var suppressEngine: Bool
    }
    var liveText: LiveText?
    @ObservationIgnored private var liveTextClearTask: Task<Void, Never>?
    @ObservationIgnored private var liveTextWatchdog: Task<Void, Never>?

    /// 开始拖动：视频层立刻撤掉这条文字，交给 SwiftUI 层。
    func beginLiveText(_ clip: TextClip) {
        liveTextClearTask?.cancel()
        liveTextWatchdog?.cancel()
        liveText = LiveText(id: clip.id, style: clip.style, suppressEngine: true)
        scheduleRebuild(immediate: true)
        // 手势万一被系统中断（onEnded 没来），别把预览永久留在「视频层不画这条文字」的状态
        liveTextWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, let live = self.liveText, live.suppressEngine else { return }
            self.endLiveText(id: live.id, x: live.style.horizontalPosition, y: live.style.verticalPosition)
        }
    }

    /// 关闭工程前把还停留在预览态的位置落盘。
    private func settleLiveText() {
        liveTextClearTask?.cancel()
        liveTextWatchdog?.cancel()
        if let live = liveText, live.suppressEngine {
            store.perform { $0.updateText(id: live.id) {
                $0.style.horizontalPosition = live.style.horizontalPosition
                $0.style.verticalPosition = live.style.verticalPosition
            } }
        }
        liveText = nil
    }

    /// 拖动过程：只改预览状态，不写工程（否则每帧都会触发全量重算与重建调度）。
    func updateLiveText(id: UUID, x: Double, y: Double) {
        guard var live = liveText, live.id == id else { return }
        live.style.horizontalPosition = x
        live.style.verticalPosition = y
        liveText = live
    }

    /// 松手：一次提交（天然就是一步撤销），视频层立即换回最终位置；
    /// SwiftUI 副本多留一会儿，盖过重建 + seek 的那一帧，避免文字闪一下。
    func endLiveText(id: UUID, x: Double, y: Double) {
        guard var live = liveText, live.id == id else { return }
        live.style.horizontalPosition = x
        live.style.verticalPosition = y
        store.perform { $0.updateText(id: id) {
            $0.style.horizontalPosition = x
            $0.style.verticalPosition = y
        } }
        live.suppressEngine = false
        liveText = live
        scheduleRebuild(immediate: true)
        liveTextWatchdog?.cancel()
        liveTextClearTask?.cancel()
        liveTextClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.liveText = nil
        }
    }

    // MARK: 字幕编辑

    /// 在右侧显示字幕样式：选中播放头处的字幕，没有则选第一条。
    func showSubtitleStyle() {
        if case .subtitle = selection { return }
        let t = playhead
        if let sub = project.subtitles.first(where: { $0.start <= t && t < $0.end }) ?? project.subtitles.first {
            selection = .subtitle(sub.id)
        }
    }

    /// 请求清空全部字幕（弹确认框）。
    var confirmClearSubtitles = false

    func clearSubtitles() {
        store.perform { $0.removeAllSubtitles() }
        if case .subtitle = selection { selection = nil }
    }

    /// 导入 SRT，替换现有字幕（可撤销）。导入的时间按当前时间线对齐。
    func importSRT() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "导入 SRT 字幕")
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = String(localized: "无法读取字幕文件")
            return
        }
        let subs = SRT.decode(data: data)
        guard !subs.isEmpty else {
            errorMessage = String(localized: "没有在文件里找到 SRT 字幕")
            return
        }
        store.perform { $0.replaceSubtitles(subs) }
        if case .subtitle = selection { selection = nil }
        notice = String(localized: "已导入 \(subs.count) 条字幕。")
    }

    func exportSRT() {
        let panel = NSSavePanel()
        panel.title = String(localized: "导出 SRT 字幕")
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = project.name + ".srt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SRT.encode(project.subtitles).write(to: url, atomically: true, encoding: .utf8)
            notice = String(localized: "已导出 \(project.subtitles.count) 条字幕。")
        } catch {
            errorMessage = String(localized: "无法写入字幕文件：\(error.localizedDescription)")
        }
    }

    func mergeSubtitleWithNext(_ id: UUID) {
        store.perform { $0.mergeSubtitleWithNext(id: id) }
        selection = .subtitle(id)
    }

    func removeSubtitle(_ id: UUID) {
        store.perform { $0.removeSubtitle(id: id) }
        if selection == .subtitle(id) { selection = nil }
    }

    func deleteSelection() {
        guard let selection else { return }
        store.perform { p in
            switch selection {
            case .video(let id): p.removeMain(id: id)
            case .music(let id): p.removeMusic(id: id)
            case .subtitle(let id): p.removeSubtitle(id: id)
            case .text(let id): p.removeText(id: id)
            case .duck(let id): p.removeDuckRange(id: id)
            case .transition(let id): p.setTransition(nil, before: id)
            }
        }
        self.selection = nil
    }

    // MARK: 文字

    /// 在播放头处添加一段文字并选中（播放头在末尾时往前挪，保证落在画面上）。
    func addText(_ preset: TextPreset) {
        var start = playhead
        if duration > .zero, start >= duration - EditLimits.minClipDuration {
            start = Time.max(.zero, duration - preset.duration)
        }
        let clip = preset.makeClip(at: start)
        store.perform { $0.addText(clip) }
        selection = .text(clip.id)
        if isPlaying { togglePlay() }
        seek(to: Time.min(duration, start + Time.min(clip.duration / 2, Time(seconds: 1))))
    }

    func duplicateText(_ id: UUID) {
        var copy: UUID?
        store.perform { copy = $0.duplicateText(id: id) }
        if let copy { selection = .text(copy) }
    }

    func removeText(_ id: UUID) {
        store.perform { $0.removeText(id: id) }
        if selection == .text(id) { selection = nil }
    }

    var selectedText: TextClip? {
        if case .text(let id) = selection { return project.text(id: id) }
        return nil
    }

    // MARK: 人声避让

    var generatingDuckRanges = false

    /// 按字幕时间生成人声区间（替换现有区间，可撤销），并给 clipID 这段音频开启避让。
    /// （原 FrameCut 的「按声音检测」依赖语音模型，未随引擎包引入；可手动添加人声区间）
    func generateDuckRanges(enableFor clipID: UUID?) {
        let ranges = DuckRange.merged(project.subtitles.map { ($0.start, $0.end) })
        guard !ranges.isEmpty else {
            notice = String(localized: "没有字幕，先添加字幕或导入 SRT，也可以手动添加人声区间。")
            return
        }
        store.perform { p in
            p.replaceDuckRanges(ranges)
            if let clipID { p.updateMusic(id: clipID) { $0.ducks = true } }
        }
        notice = String(localized: "按字幕生成了 \(ranges.count) 个人声区间，可在时间线上拖动调整；⌘Z 撤销。")
    }

    func addDuckRangeAtPlayhead() {
        var id: UUID?
        let at = playhead
        store.perform { id = $0.addDuckRange(at: at) }
        if let id { selection = .duck(id) }
    }

    // MARK: 录音（旁白）

    @ObservationIgnored private var recorder: AVAudioRecorder?
    /// 正在录音：开始的时间线位置与开始时刻。
    private(set) var recording: (start: Time, began: Date)?
    var isRecording: Bool { recording != nil }

    /// 从播放头开始录旁白：同时播放画面（静音，避免喇叭声音被录进去）。
    func startRecording() {
        guard recorder == nil else { return }
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                errorMessage = String(localized: "FrameCut 没有麦克风权限。请在「系统设置 → 隐私与安全性 → 麦克风」里允许 FrameCut。")
                return
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = formatter.string(from: Date())
            let url = ProjectFile.recordingsDirectory(for: packageURL).appendingPathComponent(String(localized: "旁白 \(stamp).m4a"))
            do {
                let r = try AVAudioRecorder(url: url, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000,
                ])
                guard r.prepareToRecord() else { throw CocoaError(.fileWriteUnknown) }
                if isPlaying { togglePlay() }
                let start = playhead
                player.isMuted = true
                r.record()
                if playhead < duration { togglePlay() }
                recorder = r
                recording = (start, Date())
            } catch {
                player.isMuted = false
                errorMessage = String(localized: "无法开始录音：\(error.localizedDescription)")
            }
        }
    }

    func stopRecording() {
        guard let r = recorder, let rec = recording else { return }
        r.stop()
        recorder = nil
        recording = nil
        player.isMuted = false
        if isPlaying { togglePlay() }
        let url = r.url
        Task {
            do {
                let asset = try await FCMedia.MediaProbe.probe(url: url)
                guard asset.duration >= Time(seconds: 0.3) else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                var id: UUID?
                store.perform { p in
                    p.addAssets([asset])
                    id = p.addMusic(assetID: asset.id, at: rec.start)
                }
                if let id { selection = .music(id) }
                notice = String(localized: "已录制 \(asset.duration.displayString) 的旁白，放在音频轨上。")
            } catch {
                errorMessage = String(localized: "录音没有保存成功：\(error.localizedDescription)")
            }
        }
    }

    /// 关闭工程时，把素材库里已经删掉的录音移到废纸篓（关闭后无法撤销，不再需要它们）。
    private func trashUnusedRecordings() {
        for url in ProjectFile.unusedRecordings(in: store.project, packageURL: packageURL) {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    // MARK: 调色工作流

    /// 复制的调色（复制 / 粘贴调色）。
    var copiedFilter: FilterSettings?
    /// 按住“对比”时预览不带调色的原图。
    var comparingOriginal = false {
        didSet { if comparingOriginal != oldValue { scheduleRebuild(immediate: true) } }
    }

    private func renderProject(_ p: Project) -> Project {
        var p = comparingOriginal ? p.withoutGrading() : p
        // 拖动中的文字改由 SwiftUI 层画，视频帧里先拿掉，避免一动就重建合成 + seek
        if let live = liveText, live.suppressEngine {
            p.texts.removeAll { $0.id == live.id }
        }
        return p
    }

    func copyGrade() {
        guard let clip = selectedClip else { return }
        copiedFilter = clip.filter
        notice = String(localized: "已复制调色。选中其他片段后按 ⌥⌘V 粘贴。")
    }

    func pasteGrade() {
        guard let filter = copiedFilter, let clip = selectedClip else { return }
        store.perform { $0.applyFilter(filter, to: [clip.id]) }
    }

    var selectedClip: VideoClip? {
        if case .video(let id) = selection { return project.mainClip(id: id) }
        return nil
    }

    // MARK: 导入

    func importFiles(_ urls: [URL], addToTimeline: Bool) async {
        importing = true
        defer { importing = false }
        var assets: [MediaAsset] = []
        var failed: [String] = []
        for url in urls {
            if let existing = project.assets.first(where: { $0.path == url.path }) {
                assets.append(existing)
                continue
            }
            do {
                assets.append(try await FCMedia.MediaProbe.probe(url: url))
            } catch {
                failed.append(url.lastPathComponent)
                Log.media.error("无法导入 \(url.lastPathComponent, privacy: .public)：\(error.localizedDescription, privacy: .public)")
            }
        }
        let at = playhead
        let wasHDR = project.colorMode == .hdr
        let wasAutoFormat = project.formatIsAutomatic
        store.perform { p in
            p.addAssets(assets)
            guard addToTimeline else { return }
            for asset in assets {
                switch asset.kind {
                case .video, .image: p.appendToMain(assetID: asset.id)
                case .audio: p.addMusic(assetID: asset.id, at: at)
                }
            }
        }
        if !failed.isEmpty { errorMessage = String(localized: "以下文件无法导入：\(failed.joined(separator: String(localized: "、", comment: "列表分隔符")))") }
        var notes: [String] = []
        if wasAutoFormat, !project.formatIsAutomatic {
            notes.append(String(localized: "已按素材设置画面为 \(project.aspect.displayName) · \(project.frameRate) fps"))
        }
        if !wasHDR, project.colorMode == .hdr {
            notes.append(String(localized: "检测到 HDR 素材，工程已切换为 HDR，预览与导出保留高光细节"))
        }
        if !notes.isEmpty { notice = notes.joined(separator: String(localized: "；", comment: "两句提示之间的分隔符")) + String(localized: "。可在右侧工程设置中修改。") }
    }

    /// 从素材库删除素材（连同时间线上用到它的片段）。
    func removeAsset(_ asset: MediaAsset) {
        let used = project.mainTrack.contains { $0.assetID == asset.id } || project.musicTrack.contains { $0.assetID == asset.id }
        if used {
            let alert = NSAlert()
            alert.messageText = String(localized: "删除“\(asset.name)”？")
            alert.informativeText = String(localized: "时间线上用到这个素材的片段也会一起删除。可以用 ⌘Z 撤销。")
            alert.addButton(withTitle: String(localized: "删除"))
            alert.addButton(withTitle: String(localized: "取消"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        store.perform { $0.removeAsset(id: asset.id) }
    }

    func importPanel(addToTimeline: Bool, audioOnly: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = audioOnly ? [.audio] : FCMedia.MediaProbe.supportedTypes
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importFiles(urls, addToTimeline: addToTimeline) }
    }

    func checkMissingAssets() {
        missingAssets = project.missingAssets { FileManager.default.fileExists(atPath: $0) }
    }

    func relink(_ asset: MediaAsset) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "重新定位：\(asset.name)")
        panel.allowedContentTypes = FCMedia.MediaProbe.supportedTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.perform { $0.relinkAsset(id: asset.id, to: url.path, bookmark: try? url.bookmarkData(options: .minimalBookmark)) }
        checkMissingAssets()
        built = nil
        scheduleRebuild(immediate: true)
    }

    // MARK: 保存

    func scheduleAutosave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        do {
            try ProjectFile.write(store.project, to: packageURL)
            lastSaved = Date()
        } catch {
            errorMessage = String(localized: "保存失败：\(error.localizedDescription)")
            Log.project.error("保存失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: 导出

    /// burnSubtitles：字幕画进视频；writeSRT：在视频旁边另存同名 .srt。
    func export(settings: ExportSettings, to url: URL, burnSubtitles: Bool = true, writeSRT: Bool = false) {
        exportState = .running(0)
        var project = store.project
        let srt = writeSRT && !project.subtitles.isEmpty ? SRT.encode(project.subtitles) : nil
        if !burnSubtitles { project.subtitles = [] }
        let started = Date()
        Log.export.info("开始导出 \(settings.shortSide)p \(settings.frameRate)fps \(settings.dynamicRange.rawValue) \(settings.effectiveCodec.rawValue)")
        exportTask = Task { [weak self] in
            do {
                try await Exporter().export(project: project, settings: settings, to: url) { p in
                    Task { @MainActor in
                        if case .running = self?.exportState { self?.exportState = .running(p) }
                    }
                }
                // 视频导出成功后再写字幕文件；已有同名 .srt 时另起名，不覆盖
                if let srt {
                    let srtURL = SRT.sidecarURL(for: url)
                    do {
                        try srt.write(to: srtURL, atomically: true, encoding: .utf8)
                        if srtURL.deletingPathExtension().lastPathComponent != url.deletingPathExtension().lastPathComponent {
                            self?.notice = String(localized: "已有同名字幕文件，新的字幕保存为「\(srtURL.lastPathComponent)」。")
                        }
                    } catch {
                        self?.errorMessage = String(localized: "视频已导出，但字幕文件写入失败：\(error.localizedDescription)")
                    }
                }
                self?.exportState = .done(url)
                Log.export.info("导出完成，用时 \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) 秒")
            } catch is CancellationError {
                self?.exportState = .idle
                Log.export.info("导出已取消")
            } catch {
                self?.exportState = .failed(error.localizedDescription)
                Log.export.error("导出失败：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        exportState = .idle
    }

    // MARK: 键盘

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if NSApp.keyWindow?.firstResponder is NSText { return event }
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false { return event }
            let keyCode = event.keyCode
            let big = event.modifierFlags.contains(.shift)
            let handled = MainActor.assumeIsolated { () -> Bool in
                switch keyCode {
                case 49: if self.isRecording { self.stopRecording() } else { self.togglePlay() } // 空格
                case 51, 117: self.deleteSelection() // Delete
                case 123: self.step(frames: big ? -10 : -1)
                case 124: self.step(frames: big ? 10 : 1)
                default: return false
                }
                return true
            }
            return handled ? nil : event
        }
    }
}
