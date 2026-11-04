import AppKit
import FCCore
import SwiftUI

/// 字幕：逐条校对、全局样式。
/// （原 FrameCut 的本地语音识别未随引擎包引入——需要 600MB Whisper 模型；
///   字幕可手动添加或导入 SRT，后续需要时再评估接入）
struct SubtitlePanel: View {
    @Bindable var model: EditorModel
    @State private var confirmReplace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    var newID: UUID?
                    let at = model.playhead
                    model.store.perform { newID = $0.addSubtitle(at: at, text: String(localized: "输入字幕")) }
                    if let newID { model.selection = .subtitle(newID) }
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .buttonStyle(PanelButtonStyle(prominent: true))
                .help("在播放头位置添加一条字幕")

                Button("导入 SRT…") { model.importSRT() }
                    .buttonStyle(PanelButtonStyle())
                    .help("从 .srt 文件导入字幕（替换现有字幕，可撤销）")

                Button("导出 SRT…") { model.exportSRT() }
                    .buttonStyle(PanelButtonStyle())
                    .disabled(model.project.subtitles.isEmpty)
                    .help("把当前字幕导出为 .srt 文件")

                Menu {
                    Toggle("字幕跟随视频剪辑", isOn: Binding(
                        get: { model.project.subtitlesFollowMain },
                        set: { on in model.store.perform { $0.subtitlesFollowMain = on; $0.subtitlesFollowIsAutomatic = false } }))
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("字幕是否跟随视频剪辑")
            }

            Button {
                model.showSubtitleStyle()
            } label: {
                Label { Text("字幕样式") } icon: { Image(systemName: "textformat").latinSymbol() }.frame(maxWidth: .infinity)
            }
            .buttonStyle(PanelButtonStyle())
            .disabled(model.project.subtitles.isEmpty)
            .help(model.project.subtitles.isEmpty ? "还没有字幕" : "在右侧调整字体、字号、颜色和位置（对全部字幕生效）")

            Divider().overlay(Theme.border)

            if model.project.subtitles.isEmpty {
                Spacer()
                Text("还没有字幕。\n点击「添加」手动输入，\n或「导入 SRT…」从字幕文件导入。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                HStack {
                    Text("共 \(model.project.subtitles.count) 条 · 点击时间跳转，右键分割 / 合并 / 删除")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    Spacer()
                    Button("清空") { model.confirmClearSubtitles = true }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                        .help("删除全部字幕（可撤销）")
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(model.project.subtitles) { sub in
                                SubtitleRow(model: model, sub: sub)
                                    .id(sub.id)
                            }
                        }
                    }
                    .onChange(of: model.selection) { _, sel in
                        if case .subtitle(let id) = sel { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
        }
        .padding(10)
        .foregroundStyle(Theme.text)
        .confirmationDialog("替换现有字幕？", isPresented: $confirmReplace) {
            Button("重新识别并替换", role: .destructive) { confirmReplace = false }
            Button("取消", role: .cancel) {}
        } message: {
            Text("识别结果会替换当前的 \(model.project.subtitles.count) 条字幕（可撤销）。")
        }
    }
}

/// 字幕右键菜单：时间线上的字幕块与字幕列表共用。
struct SubtitleContextMenu: View {
    @Bindable var model: EditorModel
    let sub: Subtitle

    private var isLast: Bool { model.project.subtitles.last?.id == sub.id }
    /// 与 splitSubtitle 的门槛一致：两边都至少留 minClipDuration。
    private var playheadInside: Bool {
        model.playhead - sub.start >= EditLimits.minClipDuration && sub.end - model.playhead >= EditLimits.minClipDuration
    }

    var body: some View {
        Button("在播放头处分割") {
            model.selection = .subtitle(sub.id)
            model.splitAtPlayhead()
        }
        .disabled(!playheadInside)
        Button("与下一条合并") { model.mergeSubtitleWithNext(sub.id) }
            .disabled(isLast)
        Divider()
        Button("删除", role: .destructive) { model.removeSubtitle(sub.id) }
        Button("清空全部字幕…", role: .destructive) { model.confirmClearSubtitles = true }
    }
}

private struct SubtitleRow: View {
    @Bindable var model: EditorModel
    let sub: Subtitle

    private var selected: Bool { model.selection == .subtitle(sub.id) }
    private var active: Bool { sub.start <= model.playhead && model.playhead < sub.end }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                model.selection = .subtitle(sub.id)
                model.seek(to: sub.start)
            } label: {
                Text(sub.start.displayString)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(active ? Theme.accent : Theme.tertiary)
                    .frame(width: 70, alignment: .leading)
                    .padding(.top, 3)
            }
            .buttonStyle(.plain)
            TextField("", text: model.subtitleBinding(sub.id, \.text, default: ""), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...3)
            Button {
                model.removeSubtitle(sub.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.tertiary)
            .padding(.top, 3)
            .help("删除这条字幕")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.hover : (active ? Theme.raised : Color.clear)))
        .contentShape(Rectangle())
        .contextMenu { SubtitleContextMenu(model: model, sub: sub) }
    }
}

/// 字幕样式（对全部字幕生效），显示在右侧检查器里。
struct SubtitleStyleEditor: View {
    @Bindable var model: EditorModel

    private let fonts: [(String, String)] = [
        ("PingFangSC-Semibold", String(localized: "苹方 粗")),
        ("PingFangSC-Regular", String(localized: "苹方 常规")),
        ("STHeitiSC-Medium", String(localized: "黑体")),
        ("STSongti-SC-Bold", String(localized: "宋体 粗")),
        ("STKaitiSC-Bold", String(localized: "楷体")),
        ("HiraginoSansGB-W6", String(localized: "冬青黑体")),
    ]

    private func style<T>(_ kp: WritableKeyPath<SubtitleStyle, T>) -> Binding<T> {
        model.projectBinding((\Project.subtitleStyle).appending(path: kp))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("字体", selection: style(\.fontName)) {
                ForEach(fonts, id: \.0) { Text($0.1).tag($0.0) }
            }
            .font(.system(size: 12))
            Text("也可以在预览画面里直接拖动字幕调整位置，拖右下角调整大小。")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledSlider(title: "字号", value: style(\.fontSize), range: SubtitleStyle.fontSizeRange,
                          format: { "\(Int($0 * 1000))" }, onEditing: model.coalesce)
            LabeledSlider(title: "上下位置", value: style(\.verticalPosition), range: 0...1,
                          format: { "\(Int($0 * 100))%" }, onEditing: model.coalesce)
            HStack(alignment: .bottom, spacing: 8) {
                LabeledSlider(title: "左右位置", value: style(\.horizontalPosition), range: 0...1,
                              format: { "\(Int($0 * 100))%" }, onEditing: model.coalesce)
                Button("居中") { model.store.perform { $0.subtitleStyle.horizontalPosition = 0.5 } }
                    .buttonStyle(PanelButtonStyle())
                    .disabled(model.project.subtitleStyle.horizontalPosition == 0.5)
            }
            LabeledSlider(title: "描边粗细", value: style(\.strokeWidth), range: 0...0.3,
                          format: { "\(Int($0 * 100))" }, onEditing: model.coalesce)
            HStack(spacing: 14) {
                ColorPicker("文字", selection: colorBinding(style(\.textColor)), supportsOpacity: false)
                ColorPicker("描边", selection: colorBinding(style(\.strokeColor)), supportsOpacity: false)
                ColorPicker("背景", selection: colorBinding(style(\.backgroundColor)), supportsOpacity: true)
            }
            .font(.system(size: 12))
            HStack(spacing: 6) {
                preset("经典白字", text: .white, stroke: .black, bg: .clear)
                preset("黄字", text: RGBA(r: 1, g: 0.86, b: 0.2), stroke: .black, bg: .clear)
                preset("黑底白字", text: .white, stroke: .clear, bg: RGBA(r: 0, g: 0, b: 0, a: 0.6), strokeWidth: 0)
            }
        }
    }

    private func preset(_ name: LocalizedStringKey, text: RGBA, stroke: RGBA, bg: RGBA, strokeWidth: Double = 0.12) -> some View {
        Button(name) {
            model.store.perform {
                $0.subtitleStyle.textColor = text
                $0.subtitleStyle.strokeColor = stroke
                $0.subtitleStyle.backgroundColor = bg
                $0.subtitleStyle.strokeWidth = strokeWidth
            }
        }
        .buttonStyle(PanelButtonStyle())
    }
}
