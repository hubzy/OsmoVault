import AppKit
import FCCore
import SwiftUI

/// 右侧检查器：头部固定（滚动时始终知道在编辑哪个对象），内容按分组卡片排布。
struct InspectorPanel: View {
    @Bindable var model: EditorModel
    /// 基础 / 调色页放在头部，滚动到参数堆里也能随时切页；切片段不重置。
    @AppStorage("inspector.videoTab") private var videoTab = "basic"

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.panel)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
        .foregroundStyle(Theme.text)
    }

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorHeader(title: header.title, icon: header.icon)
            if let subtitle = header.subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if isVideo {
                Picker("", selection: $videoTab) {
                    Text("基础").tag("basic")
                    Text("调色").tag("grade")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var isVideo: Bool {
        if case .video(let id) = model.selection { return model.project.mainClip(id: id) != nil }
        return false
    }

    private var header: (title: LocalizedStringKey, icon: String, subtitle: String?) {
        switch model.selection {
        case .video(let id):
            guard let clip = model.project.mainClip(id: id) else { return ("工程设置", "slider.horizontal.3", nil) }
            let asset = model.project.asset(id: clip.assetID)
            return (asset?.kind == .image ? "照片" : "视频",
                    asset?.kind == .image ? "photo" : "film", asset?.name)
        case .music(let id):
            let asset = model.project.music(id: id).flatMap { model.project.asset(id: $0.assetID) }
            return ("音频", "music.note", asset?.name)
        case .transition:
            return ("转场", "square.split.diagonal", nil)
        case .subtitle(let id):
            let sub = model.project.subtitle(id: id)
            return ("字幕", "captions.bubble", sub.map { "\($0.start.displayString) – \($0.end.displayString)" })
        case .text(let id):
            let clip = model.project.text(id: id)
            return ("文字", "textformat", clip.map { "\($0.start.displayString) – \($0.end.displayString)" })
        case .duck(let id):
            let range = model.project.duckRanges.first { $0.id == id }
            return ("人声区间", "waveform.badge.minus", range.map { "\($0.start.displayString) – \($0.end.displayString)" })
        default:
            return ("工程设置", "slider.horizontal.3", nil)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.selection {
        case .video(let id) where model.project.mainClip(id: id) != nil:
            VideoInspector(model: model, id: id, tab: $videoTab)
        case .music(let id) where model.project.music(id: id) != nil:
            MusicInspector(model: model, id: id)
        case .transition(let id) where model.project.mainClip(id: id) != nil:
            TransitionInspector(model: model, id: id)
        case .subtitle(let id) where model.project.subtitle(id: id) != nil:
            SubtitleInspector(model: model, id: id)
        case .text(let id) where model.project.text(id: id) != nil:
            TextInspector(model: model, id: id)
        case .duck(let id) where model.project.duckRanges.contains(where: { $0.id == id }):
            DuckRangeInspector(model: model, id: id)
        default:
            ProjectInspector(model: model)
        }
    }
}

struct InspectorHeader: View {
    let title: LocalizedStringKey
    let icon: String

    var body: some View {
        Label { Text(title) } icon: { Image(systemName: icon).latinSymbol() }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.text)
    }
}

// MARK: - 工程

private struct ProjectInspector: View {
    @Bindable var model: EditorModel

    private var screenSupportsHDR: Bool {
        (NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
    }

    private var colorModeHint: String {
        switch model.project.colorMode {
        case .hdr:
            let screen = screenSupportsHDR ? String(localized: "当前屏幕支持 HDR 预览。") : String(localized: "当前屏幕不支持 HDR，预览会自动压缩亮度，导出不受影响。")
            return String(localized: "保留 HDR 素材的高光与色彩，可导出 HDR（HLG / HDR10）或 SDR。") + screen
        case .sdr:
            return model.project.hasHDRAssets ? String(localized: "HDR 素材会自动做色调映射，高光平滑压缩而不过曝。") : String(localized: "普通视频。导入 HDR 素材（如 iPhone 拍摄）时会自动切换为 HDR。")
        }
    }

    var body: some View {
        InspectorGroup("画面比例", key: "project.aspect") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], spacing: 6) {
                ForEach(AspectRatio.allCases, id: \.self) { aspect in
                    Button {
                        guard aspect != model.project.aspect else { return }
                        model.store.perform { $0.setAspect(aspect) }
                    } label: {
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(model.project.aspect == aspect ? Theme.accent : Theme.secondary, lineWidth: 1.5)
                                .frame(width: aspect.ratio >= 1 ? 26 : 26 * aspect.ratio, height: aspect.ratio >= 1 ? 26 / aspect.ratio : 26)
                                .frame(height: 30)
                            Text(aspect.displayName).font(.system(size: 11))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(model.project.aspect == aspect ? Theme.accent : Theme.text)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        InspectorGroup("色彩与帧率", key: "project.color") {
            SectionTitle("色彩")
            Picker("", selection: Binding(get: { model.project.colorMode },
                                          set: { mode in
                                              // 点已选中的那一项不算手动设置，避免关掉自动切换和产生空撤销
                                              guard mode != model.project.colorMode else { return }
                                              model.store.perform { $0.setColorMode(mode) }
                                          })) {
                Text("SDR").tag(ColorMode.sdr)
                Text("HDR").tag(ColorMode.hdr)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(colorModeHint).font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            SectionTitle("帧率（fps）")
            Picker("", selection: Binding(get: { model.project.frameRate },
                                          set: { fps in
                                              guard fps != model.project.frameRate else { return }
                                              model.store.perform { $0.setFrameRate(fps) }
                                          })) {
                ForEach(Project.frameRates, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        InspectorGroup("统计", key: "project.stats", defaultExpanded: false) {
            Text("片段 \(model.project.mainTrack.count) · 音频 \(model.project.musicTrack.count) · 文字 \(model.project.texts.count) · 字幕 \(model.project.subtitles.count)")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            Text("总时长 \(model.duration.displayString)").font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }

        Text("提示：在时间线上点选片段、音频、文字、字幕或转场，可在这里调整它们的属性。")
            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 视频片段

private struct VideoInspector: View {
    @Bindable var model: EditorModel
    let id: UUID
    @Binding var tab: String
    @State private var hslBand: HSLBand = .orange

    private var clip: VideoClip? { model.project.mainClip(id: id) }
    private var asset: MediaAsset? { clip.flatMap { model.project.asset(id: $0.assetID) } }

    private var detachHelp: String {
        if asset?.hasAudio == false { return String(localized: "这段视频没有声音") }
        if clip.map({ $0.speed != 1 }) == true { return String(localized: "变速的片段不能分离音频，先把速度调回 1x") }
        if clip?.muted == true { return String(localized: "原声已静音或已分离。要重新分离，先取消静音") }
        return String(localized: "把原声放到音频轨上单独剪辑、调节，原片段静音。之后移动或修剪画面，音频不会跟着变。")
    }

    var body: some View {
        if tab == "grade" { gradeContent } else { basicContent }
    }

    @ViewBuilder
    private var basicContent: some View {
        InspectorGroup("画面变换", key: "video.transform", actionTitle: "重置", action: {
            model.store.perform { $0.updateMain(id: id) { $0.transform = ClipTransform() } }
        }) {
            LabeledSlider(title: "缩放", value: model.clipBinding(id, \.transform.scale, default: 1), range: 0.5...3,
                          format: { "\(Int($0 * 100))%" }, onEditing: model.coalesce, resetValue: 1)
            LabeledSlider(title: "水平位置", value: model.clipBinding(id, \.transform.offsetX, default: 0), range: -1...1,
                          format: { String(format: "%.2f", $0) }, onEditing: model.coalesce, resetValue: 0)
            LabeledSlider(title: "垂直位置", value: model.clipBinding(id, \.transform.offsetY, default: 0), range: -1...1,
                          format: { String(format: "%.2f", $0) }, onEditing: model.coalesce, resetValue: 0)
            HStack {
                Text("旋转").font(.system(size: 12))
                Spacer()
                Button {
                    model.store.perform { $0.updateMain(id: id) { $0.transform.quarterTurns = ($0.transform.quarterTurns + 1) % 4 } }
                } label: {
                    Label("\((clip?.transform.quarterTurns ?? 0) * 90)°", systemImage: "rotate.right")
                }
                .buttonStyle(PanelButtonStyle())
            }
        }

        if asset?.kind == .video {
            InspectorGroup("变速", key: "video.speed") {
                LabeledSlider(title: "速度", value: Binding(
                    get: { clip?.speed ?? 1 },
                    set: { v in model.store.perform { $0.setSpeed(id: id, v) } }
                ), range: 0.25...4, format: { String(format: "%.2fx", $0) }, onEditing: model.coalesce, resetValue: 1)
                HStack(spacing: 6) {
                    ForEach([0.5, 1, 1.5, 2], id: \.self) { s in
                        Button(String(format: s == 1 ? "1x" : "%.1fx", s)) { model.store.perform { $0.setSpeed(id: id, s) } }
                            .buttonStyle(PanelButtonStyle(prominent: clip?.speed == s))
                    }
                }
            }
            InspectorGroup("原声", key: "video.audio") {
                Toggle("静音", isOn: model.clipBinding(id, \.muted, default: false)).toggleStyle(.switch).controlSize(.small)
                LabeledSlider(title: "音量", value: model.clipBinding(id, \.volume, default: 1), range: 0...2,
                              format: { "\(Int($0 * 100))%" }, onEditing: model.coalesce, resetValue: 1)
                    .disabled(clip?.muted == true)
                Button("分离音频") { model.detachAudio(id) }
                    .buttonStyle(PanelButtonStyle())
                    .disabled(!model.project.canDetachAudio(id: id))
                    .help(detachHelp)
            }
        } else {
            InspectorGroup("时长", key: "photo.duration") {
                LabeledSlider(title: "显示时长", value: Binding(
                    get: { clip?.sourceDuration.seconds ?? 3 },
                    set: { v in
                        guard let clip else { return }
                        model.store.perform { $0.trimMain(id: id, sourceIn: clip.sourceIn, sourceOut: clip.sourceIn + Time(seconds: v)) }
                    }
                ), range: 0.5...15, format: { String(format: String(localized: "%.1f 秒"), $0) },
                           onEditing: model.coalesce, resetValue: 3)
            }
        }
    }

    @ViewBuilder
    private var gradeContent: some View {
        HStack(spacing: 6) {
            Text("风格：\(styleName)（在左侧「滤镜」中选择）")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("重置全部") {
                model.store.perform { $0.updateMain(id: id) { $0.filter.resetAdjustments() } }
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
        }

        InspectorGroup("光效", key: "grade.light") {
            adjust("亮度", \.filter.brightness)
            adjust("对比度", \.filter.contrast)
            adjust("高光", \.filter.highlights)
            adjust("阴影", \.filter.shadows)
        }

        InspectorGroup("色彩", key: "grade.color") {
            adjust("饱和度", \.filter.saturation)
            adjust("自然饱和度", \.filter.vibrance)
            adjust("色温", \.filter.temperature)
            adjust("色调", \.filter.tint)
        }

        InspectorGroup("细节", key: "grade.detail", defaultExpanded: false) {
            adjust("锐化", \.filter.sharpen, range: 0...1)
            adjust("暗角", \.filter.vignette, range: 0...1)
        }

        InspectorGroup("HSL 分色", key: "grade.hsl", defaultExpanded: false,
                       actionTitle: "重置", action: {
                           model.store.perform { $0.updateMain(id: id) { $0.filter.hsl = [:] } }
                       }) {
            HStack(spacing: 6) {
                ForEach(HSLBand.allCases, id: \.self) { band in
                    Button { hslBand = band } label: {
                        Circle().fill(Self.swatch(band))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().stroke(hslBand == band ? Theme.text : .clear, lineWidth: 2).padding(-3))
                            .overlay(alignment: .topTrailing) {
                                if !(clip?.filter.hsl[band]?.isIdentity ?? true) {
                                    Circle().fill(Theme.accent).frame(width: 6, height: 6).offset(x: 3, y: -3)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(hslBand == band ? String(localized: "\(band.displayName)（正在调整）") : band.displayName)
                }
            }
            .frame(maxWidth: .infinity)
            Text("调整画面中\(hslBand.displayName)色的部分，如天空用蓝、肤色用橙、草地用绿。")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            hslSlider("色相", \.hue)
            hslSlider("饱和度", \.saturation)
            hslSlider("亮度", \.luminance)
        }
    }

    private func hslSlider(_ title: LocalizedStringKey, _ kp: WritableKeyPath<HSLAdjust, Double>) -> some View {
        let band = hslBand
        let value = Binding<Double>(
            get: { model.project.mainClip(id: id)?.filter.hsl[band]?[keyPath: kp] ?? 0 },
            set: { v in model.store.perform { $0.updateMain(id: id) { c in
                var adj = c.filter.hsl[band] ?? HSLAdjust()
                adj[keyPath: kp] = v
                c.filter.hsl[band] = adj.isIdentity ? nil : adj
            } } }
        )
        return LabeledSlider(title: title, value: value, range: -1...1,
                             format: { String(format: "%+.0f", $0 * 100) },
                             onEditing: model.coalesce, resetValue: 0)
    }

    private var styleName: String {
        guard let f = clip?.filter else { return "" }
        return f.lut?.name ?? f.preset.displayName
    }

    private static func swatch(_ band: HSLBand) -> Color {
        Color(hue: band.hueCenter / 360, saturation: 0.75, brightness: 0.95)
    }

    private func adjust(_ title: LocalizedStringKey, _ kp: WritableKeyPath<VideoClip, Double>, range: ClosedRange<Double> = -1...1) -> some View {
        LabeledSlider(title: title, value: model.clipBinding(id, kp, default: 0), range: range,
                      format: { String(format: range.lowerBound < 0 ? "%+.0f" : "%.0f", $0 * 100) },
                      onEditing: model.coalesce, resetValue: 0)
    }
}

// MARK: - 音乐

private struct MusicInspector: View {
    @Bindable var model: EditorModel
    let id: UUID

    var body: some View {
        if let clip = model.project.music(id: id) {
            InspectorGroup("片段", key: "music.clip") {
                Text("音频轨 \(clip.lane + 1) · \(clip.start.displayString) – \(clip.end.displayString)")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondary)
                Toggle("静音", isOn: model.musicBinding(id, \.muted, default: false)).font(.system(size: 12))
                LabeledSlider(title: "音量", value: model.musicBinding(id, \.volume, default: 1), range: 0...2,
                              format: { "\(Int($0 * 100))%" }, onEditing: model.coalesce, resetValue: 1)
                LabeledSlider(title: "淡入", value: model.seconds(model.musicBinding(id, \.fadeIn, default: .zero)), range: 0...5,
                              format: { String(format: String(localized: "%.1f 秒"), $0) }, onEditing: model.coalesce, resetValue: 0)
                LabeledSlider(title: "淡出", value: model.seconds(model.musicBinding(id, \.fadeOut, default: .zero)), range: 0...5,
                              format: { String(format: String(localized: "%.1f 秒"), $0) }, onEditing: model.coalesce, resetValue: 0)
            }
            Text("在时间线上左右拖动调整位置，上下拖动换到其他音频轨；拖动两端可裁剪，⌘B 在播放头处分割。配乐、旁白、音效可以放在不同的轨上同时播放。")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            AudioLaneSection(model: model, lane: clip.lane)
            DuckingSection(model: model, clipID: id)
        }
    }
}

// MARK: - 转场

private struct TransitionInspector: View {
    @Bindable var model: EditorModel
    let id: UUID

    private var transition: FCCore.Transition? { model.project.transitions[id] }
    private var effective: Time? { model.layout.placement(for: id)?.transitionIn?.duration }

    var body: some View {
        Picker("效果", selection: Binding<TransitionKind?>(
            get: { transition?.kind },
            set: { kind in
                model.store.perform { p in
                    p.setTransition(kind.map { FCCore.Transition(kind: $0, duration: transition?.duration ?? FCCore.Transition.defaultDuration) }, before: id)
                }
            }
        )) {
            Text("无").tag(TransitionKind?.none)
            ForEach(TransitionKind.allCases, id: \.self) { Text($0.displayName).tag(TransitionKind?.some($0)) }
        }
        if transition != nil {
            InspectorGroup("时长", key: "transition.duration") {
                LabeledSlider(title: "时长", value: Binding(
                    get: { transition?.duration.seconds ?? 0.5 },
                    set: { v in model.store.perform { $0.transitions[id]?.duration = Time(seconds: v) } }
                ), range: 0.2...2, format: { String(format: String(localized: "%.1f 秒"), $0) },
                           onEditing: model.coalesce, resetValue: FCCore.Transition.defaultDuration.seconds)
                if let effective, let transition, effective < transition.duration {
                    Text("片段较短，实际转场时长为 \(String(format: "%.2f", effective.seconds)) 秒")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            Button("应用到全部交界") {
                if let transition { model.store.perform { $0.applyTransitionToAll(transition) } }
            }
            .buttonStyle(PanelButtonStyle())
        }
    }
}

// MARK: - 字幕

private struct SubtitleInspector: View {
    @Bindable var model: EditorModel
    let id: UUID

    var body: some View {
        TextField("字幕内容", text: model.subtitleBinding(id, \.text, default: ""), axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...5)
        Button("删除这条字幕", role: .destructive) { model.deleteSelection() }
            .buttonStyle(PanelButtonStyle())
        InspectorGroup("样式（全部字幕）", key: "subtitle.style") {
            SubtitleStyleEditor(model: model)
        }
    }
}
