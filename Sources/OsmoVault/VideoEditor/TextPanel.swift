import AppKit
import CoreImage
import FCCore
import FCEngine
import SwiftUI

// MARK: - 预设

/// 文字预设：一键添加常用的 vlog 文字样式。
struct TextPreset: Identifiable {
    let id: String
    let name: String
    let text: String
    let style: SubtitleStyle
    let animation: TextAnimation
    var duration = TextClip.defaultDuration

    func makeClip(at start: Time) -> TextClip {
        TextClip(start: start, end: start + duration, text: text, style: style, animation: animation)
    }

    private static func style(_ font: String, size: Double, color: RGBA = .white, stroke: RGBA = .black, strokeWidth: Double = 0,
                              background: RGBA = .clear, x: Double = 0.5, y: Double = 0.5) -> SubtitleStyle {
        var s = SubtitleStyle()
        s.fontName = font
        s.fontSize = size
        s.textColor = color
        s.strokeColor = stroke
        s.strokeWidth = strokeWidth
        s.backgroundColor = background
        s.horizontalPosition = x
        s.verticalPosition = y
        return s
    }

    static var all: [TextPreset] {
        let today = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)).replacingOccurrences(of: "/", with: ".")
        let yellow = RGBA(r: 1, g: 0.86, b: 0.2)
        return [
            TextPreset(id: "plain", name: String(localized: "默认文字"), text: String(localized: "输入文字"),
                       style: style("PingFangSC-Semibold", size: 0.07, strokeWidth: 0.08), animation: .fade),
            TextPreset(id: "headline", name: String(localized: "大标题"), text: String(localized: "我的周末"),
                       style: style("PingFangSC-Semibold", size: 0.12, stroke: RGBA(r: 0, g: 0, b: 0, a: 0.6), strokeWidth: 0.06, y: 0.45),
                       animation: .rise),
            TextPreset(id: "cinema", name: String(localized: "电影片名"), text: String(localized: "片 名"),
                       style: style("STSongti-SC-Black", size: 0.09), animation: .fade, duration: Time(seconds: 4)),
            TextPreset(id: "location", name: String(localized: "地点"), text: String(localized: "📍 京都 · 岚山"),
                       style: style("PingFangSC-Semibold", size: 0.045, background: RGBA(r: 0, g: 0, b: 0, a: 0.45), x: 0.22, y: 0.88),
                       animation: .rise),
            TextPreset(id: "date", name: String(localized: "日期"), text: today,
                       style: style("Futura-Bold", size: 0.05, strokeWidth: 0.1, x: 0.85, y: 0.1), animation: .typewriter),
            TextPreset(id: "chapter", name: String(localized: "章节"), text: "Day 1",
                       style: style("AvenirNext-Heavy", size: 0.1, color: yellow, strokeWidth: 0.1), animation: .pop),
            TextPreset(id: "script", name: String(localized: "手写"), text: "Hello, Autumn",
                       style: style("SnellRoundhand-Bold", size: 0.1, strokeWidth: 0.04), animation: .fade),
            TextPreset(id: "ending", name: String(localized: "片尾"), text: String(localized: "谢谢观看"),
                       style: style("STKaitiSC-Black", size: 0.07), animation: .fade),
        ]
    }

    /// 文字可选字体（系统自带，不需要下载）。
    static let fonts: [(String, String)] = [
        ("PingFangSC-Semibold", String(localized: "苹方 粗")),
        ("PingFangSC-Regular", String(localized: "苹方 常规")),
        ("STHeitiSC-Medium", String(localized: "黑体")),
        ("HiraginoSansGB-W6", String(localized: "冬青黑体")),
        ("STSongti-SC-Black", String(localized: "宋体 特粗")),
        ("STSongti-SC-Bold", String(localized: "宋体 粗")),
        ("STKaitiSC-Black", String(localized: "楷体 特粗")),
        ("STKaitiSC-Bold", String(localized: "楷体")),
        ("AvenirNext-Heavy", "Avenir Next"),
        ("Futura-Bold", "Futura"),
        ("HelveticaNeue-CondensedBlack", String(localized: "Helvetica 窄体")),
        ("Georgia-BoldItalic", String(localized: "Georgia 斜体")),
        ("SnellRoundhand-Bold", String(localized: "手写体")),
    ]
}

// MARK: - 素材库：文字

struct TextTab: View {
    @Bindable var model: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if model.project.mainTrack.isEmpty {
                    Text("先添加视频或照片，再给画面加文字。")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                } else {
                    Text("点一下添加到播放头位置。")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(TextPreset.all) { preset in
                        PresetCard(preset: preset) { model.addText(preset) }
                            .disabled(model.project.mainTrack.isEmpty)
                    }
                }
            }
            .padding(10)
        }
        .foregroundStyle(Theme.text)
    }
}

private struct PresetCard: View {
    let preset: TextPreset
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [Theme.previewTop, Theme.previewBottom], startPoint: .top, endPoint: .bottom))
                    Text(preset.text)
                        .font(.custom(preset.style.fontName, size: 15))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(preset.style.textColor.color)
                        .shadow(color: preset.style.strokeWidth > 0 ? preset.style.strokeColor.color.opacity(0.8) : .clear, radius: 1)
                        .padding(.horizontal, preset.style.backgroundColor.a > 0 ? 6 : 0)
                        .padding(.vertical, preset.style.backgroundColor.a > 0 ? 2 : 0)
                        .background(preset.style.backgroundColor.color, in: RoundedRectangle(cornerRadius: 3))
                        .padding(.horizontal, 6)
                }
                .frame(height: 54)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(hovering && enabled ? Theme.accent : Theme.border))
                Text(preset.name).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help("动画：\(preset.animation.displayName)")
    }
}

// MARK: - 检查器：文字

struct TextInspector: View {
    @Bindable var model: EditorModel
    let id: UUID

    private func style<T>(_ kp: WritableKeyPath<SubtitleStyle, T>) -> Binding<T> {
        Binding(
            // 拖动期间位置还没写进工程，检查器读实时样式才不会停在旧数值上
            get: {
                let live = model.liveText?.id == id ? model.liveText?.style : nil
                return (live ?? model.project.text(id: id)?.style ?? TextClip.defaultStyle)[keyPath: kp]
            },
            set: { value in model.store.perform { $0.updateText(id: id) { $0.style[keyPath: kp] = value } } }
        )
    }

    private var duration: Binding<Double> {
        Binding(
            get: { model.project.text(id: id)?.duration.seconds ?? 3 },
            set: { v in model.store.perform { $0.updateText(id: id) { $0.end = $0.start + Time(seconds: v) } } }
        )
    }

    var body: some View {
        // 标题 / 时间范围由 InspectorPanel 的固定头部统一显示，这里只放内容
        TextField("文字内容", text: model.textBinding(id, \.text, default: ""), axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...5)

        InspectorGroup("内容与动画", key: "text.basic") {
            LabeledSlider(title: "时长", value: duration, range: 0.5...15,
                          format: { String(format: String(localized: "%.1f 秒"), $0) },
                          onEditing: model.coalesce, resetValue: TextClip.defaultDuration.seconds)
            Picker("动画", selection: model.textBinding(id, \.animation, default: .fade)) {
                ForEach(TextAnimation.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .font(.system(size: 12))
            Picker("字体", selection: style(\.fontName)) {
                ForEach(TextPreset.fonts, id: \.0) { Text($0.1).tag($0.0) }
            }
            .font(.system(size: 12))
        }

        InspectorGroup("位置与样式", key: "text.style") {
            LabeledSlider(title: "字号", value: style(\.fontSize), range: TextClip.fontSizeRange,
                          format: { "\(Int($0 * 1000))" }, onEditing: model.coalesce,
                          resetValue: TextClip.defaultStyle.fontSize)
            LabeledSlider(title: "上下位置", value: style(\.verticalPosition), range: 0...1,
                          format: { "\(Int($0 * 100))%" }, onEditing: model.coalesce,
                          resetValue: TextClip.defaultStyle.verticalPosition)
            LabeledSlider(title: "左右位置", value: style(\.horizontalPosition), range: 0...1,
                          format: { "\(Int($0 * 100))%" }, onEditing: model.coalesce,
                          resetValue: TextClip.defaultStyle.horizontalPosition)
            LabeledSlider(title: "描边粗细", value: style(\.strokeWidth), range: 0...0.3,
                          format: { "\(Int($0 * 100))" }, onEditing: model.coalesce,
                          resetValue: TextClip.defaultStyle.strokeWidth)
            HStack(spacing: 14) {
                ColorPicker("文字", selection: colorBinding(style(\.textColor)), supportsOpacity: false)
                ColorPicker("描边", selection: colorBinding(style(\.strokeColor)), supportsOpacity: true)
                ColorPicker("背景", selection: colorBinding(style(\.backgroundColor)), supportsOpacity: true)
            }
            .font(.system(size: 12))
        }

        Text("也可以在预览画面里直接拖动文字调整位置，拖右下角调整大小。数值前的圆点可复位（左右位置即水平居中），也可以直接键入数值。")
            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
            Button("复制一份") { model.duplicateText(id) }
                .buttonStyle(PanelButtonStyle())
            Button("删除", role: .destructive) { model.removeText(id) }
                .buttonStyle(PanelButtonStyle())
        }
    }
}

// MARK: - 预览：直接调整文字

/// 预览画面上直接调整文字：点击选中，双击修改文字，拖动移动（靠近中线自动吸附），拖右下角或双指捏合缩放。暂停时可操作。
struct TextOverlay: View {
    @Bindable var model: EditorModel
    let canvas: CGSize

    var body: some View {
        if !model.isPlaying, !model.comparingOriginal {
            let t = model.playhead
            ZStack(alignment: .topLeading) {
                // 拖动中的文字由 SwiftUI 直接画（和视频渲染器同一张位图），
                // 不经过 videoComposition 重建 + 精确 seek，鼠标怎么动它就怎么动。
                // Group 固定占一个子视图位置：条件出现 / 消失不会挪动 ForEach 的
                // 结构身份，否则 TextBox 的 @State（拖动起点）会被重置。
                Group {
                    if let live = model.liveText,
                       let clip = model.project.text(id: live.id),
                       clip.start <= t, t < clip.end {
                        LiveTextLayer(clip: clip, style: live.style, canvas: canvas, at: t)
                            .allowsHitTesting(false)
                    }
                }
                ForEach(model.project.texts.filter { $0.start <= t && t < $0.end }) { clip in
                    if model.previewEditing == clip.id {
                        // 文字删空时没有排版结果，编辑框留在原位置
                        PreviewTextEditor(model: model, text: model.textBinding(clip.id, \.text, default: ""), style: clip.style,
                                          rect: TextRenderer.frame(of: clip, canvas: canvas) ?? clip.style.frame(textSize: .zero, canvas: canvas),
                                          canvas: canvas)
                    } else if let rect = TextRenderer.frame(of: clip, canvas: canvas) {
                        TextBox(model: model, clip: clip, rect: rect, canvas: canvas)
                    }
                }
            }
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        }
    }
}

private struct TextBox: View {
    @Bindable var model: EditorModel
    let clip: TextClip
    let rect: CGRect
    let canvas: CGSize

    @State private var dragStart: SubtitleStyle?
    /// 拖动中的实时样式：只驱动视图，不写工程，选框和文字都即时跟手。
    @State private var dragStyle: SubtitleStyle?
    @State private var resizeStart: (size: Double, distance: CGFloat)?
    @State private var pinchStart: Double?
    @State private var snap: (x: Bool, y: Bool) = (false, false)
    @State private var hovering = false

    /// 吸附到画面中线的距离（点）。
    private let snapDistance: CGFloat = 8

    private var selected: Bool { model.selection == .text(clip.id) }

    /// 拖动中用实时样式算位置，避免「改工程 → 等整棵视图树重算」的往返。
    private var boxRect: CGRect {
        (dragStyle ?? clip.style).frame(textSize: rect.size, canvas: canvas)
    }

    var body: some View {
        let r = boxRect
        let active = hovering || dragStart != nil || resizeStart != nil || selected
        ZStack(alignment: .topLeading) {
            if snap.x {
                Rectangle().fill(Theme.accent).frame(width: 1, height: canvas.height).offset(x: canvas.width / 2)
            }
            if snap.y {
                Rectangle().fill(Theme.accent).frame(width: canvas.width, height: 1).offset(y: canvas.height / 2)
            }
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(active ? Theme.accent : Color.clear, style: StrokeStyle(lineWidth: 1, dash: selected ? [] : [3]))
                    .contentShape(Rectangle())
                    .frame(width: r.width + 8, height: r.height + 8)
                    .onTapGesture(count: 2) { model.beginPreviewEditing(.text(clip.id), id: clip.id) }
                    .onTapGesture { model.selection = .text(clip.id) }
                    .gesture(moveGesture)
                    .simultaneousGesture(pinchGesture)
                    .help("双击修改文字，拖动调整位置，拖右下角或双指捏合调整大小")
                Circle().fill(Theme.accent)
                    .onContentHandleRing()
                    .frame(width: 10, height: 10)
                    .opacity(active ? 1 : 0)
                    .contentShape(Rectangle().inset(by: -6))
                    .offset(x: 5, y: 5)
                    .gesture(resizeGesture(r))
            }
            .onHover { hovering = $0 }
            .offset(x: r.minX - 4, y: r.minY - 4)
        }
        .onDisappear { hovering = false }
    }

    private func update(_ body: @escaping (inout SubtitleStyle) -> Void) {
        model.store.perform { $0.updateText(id: clip.id) { body(&$0.style) } }
    }

    /// 由固定坐标空间里的鼠标位移算出新位置（含中线吸附）。
    private func position(start: SubtitleStyle, dx: CGFloat, dy: CGFloat) -> (x: Double, y: Double) {
        var x = start.horizontalPosition * canvas.width + dx
        var y = start.verticalPosition * canvas.height + dy
        let sx = abs(x - canvas.width / 2) < snapDistance
        let sy = abs(y - canvas.height / 2) < snapDistance
        if sx { x = canvas.width / 2 }
        if sy { y = canvas.height / 2 }
        snap = (sx, sy)
        return (min(1, max(0, x / canvas.width)), min(1, max(0, y / canvas.height)))
    }

    private var moveGesture: some Gesture {
        // 用画布这个固定坐标空间：选框自己跟着移动时，位移基准也不会漂
        DragGesture(minimumDistance: 2, coordinateSpace: .named("subtitleCanvas"))
            .onChanged { v in
                let dx = v.location.x - v.startLocation.x
                let dy = v.location.y - v.startLocation.y
                if dragStart == nil {
                    dragStart = clip.style
                    model.selection = .text(clip.id)
                    model.beginLiveText(clip)
                }
                guard let start = dragStart else { return }
                let p = position(start: start, dx: dx, dy: dy)
                var s = clip.style
                s.horizontalPosition = p.x
                s.verticalPosition = p.y
                dragStyle = s
                model.updateLiveText(id: clip.id, x: p.x, y: p.y)
            }
            .onEnded { v in
                let dx = v.location.x - v.startLocation.x
                let dy = v.location.y - v.startLocation.y
                if let start = dragStart {
                    let p = position(start: start, dx: dx, dy: dy)
                    model.endLiveText(id: clip.id, x: p.x, y: p.y)
                }
                dragStart = nil
                dragStyle = nil
                snap = (false, false)
            }
    }

    /// 拖角缩放：按手指到文字中心的距离变化等比缩放字号。
    private func resizeGesture(_ rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("subtitleCanvas"))
            .onChanged { v in
                let center = CGPoint(x: rect.midX, y: rect.midY)
                func distance(_ p: CGPoint) -> CGFloat { max(1, hypot(p.x - center.x, p.y - center.y)) }
                if resizeStart == nil {
                    resizeStart = (clip.style.fontSize, distance(v.startLocation))
                    model.selection = .text(clip.id)
                    model.store.beginCoalescing()
                }
                guard let start = resizeStart else { return }
                let size = clamp(start.size * Double(distance(v.location) / start.distance))
                update { $0.fontSize = size }
            }
            .onEnded { _ in
                resizeStart = nil
                model.store.endCoalescing()
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if pinchStart == nil {
                    pinchStart = clip.style.fontSize
                    model.store.beginCoalescing()
                }
                guard let start = pinchStart else { return }
                let size = clamp(start * v.magnification)
                update { $0.fontSize = size }
            }
            .onEnded { _ in
                pinchStart = nil
                model.store.endCoalescing()
            }
    }

    private func clamp(_ size: Double) -> Double {
        min(TextClip.fontSizeRange.upperBound, max(TextClip.fontSizeRange.lowerBound, size))
    }
}

// MARK: - 拖动时顶替视频层的文字

/// 直接画渲染器生成的那张位图：字号、描边、背景、动画与视频帧一致，但位置每帧即时更新。
private struct LiveTextLayer: View {
    let clip: TextClip
    let style: SubtitleStyle
    let canvas: CGSize
    let at: Time

    var body: some View {
        let look = clip.appearance(at: at)
        if look.opacity > 0.001, look.visibleCharacters != 0,
           let cg = LiveTextBitmap.shared.image(text: clip.text, style: style, canvas: canvas,
                                                visible: look.visibleCharacters),
           cg.width > 0, cg.height > 0 {
            let rect = style.frame(textSize: CGSize(width: cg.width, height: cg.height), canvas: canvas)
            Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
                .resizable()
                .frame(width: rect.width, height: rect.height)
                .scaleEffect(CGFloat(look.scale))
                .offset(y: CGFloat(look.offsetY) * canvas.height)
                .opacity(look.opacity)
                .position(x: rect.midX, y: rect.midY)
        }
    }
}

/// 位图缓存：拖动只改位置，文字 / 字号 / 画布不变时不重复栅格化、不重复转 CGImage。
private final class LiveTextBitmap {
    static let shared = LiveTextBitmap()
    private let context = CIContext()
    private var key = ""
    private var cg: CGImage?

    func image(text: String, style: SubtitleStyle, canvas: CGSize, visible: Int?) -> CGImage? {
        var look = style
        look.horizontalPosition = 0
        look.verticalPosition = 0
        let key = "\(text)|\(look.hashValue)|\(Int(canvas.width))x\(Int(canvas.height))|\(visible.map { String($0) } ?? "all")"
        if key == self.key { return cg }
        let out = SubtitleRenderer.image(text: text, style: style, canvas: canvas,
                                        visibleCharacters: visible).flatMap {
            context.createCGImage($0, from: $0.extent)
        }
        self.key = key
        cg = out
        return out
    }
}
