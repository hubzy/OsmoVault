import AppKit
import SwiftUI

/// 主题：跟随 macOS 原生外观（浅色 / 深色自动切换）。
///
/// 底色、文字、分隔线用系统语义色，强调色用系统主题色
/// （controlAccentColor，随用户在「系统设置 → 外观」里选的颜色走）。
/// 片段色是内容色（时间线卡片底），两种外观下都够对比，保持不变。
///
/// 时间线这一层（轨道底、时间尺、选中描边、修剪手柄、播放头等）以前是按
/// 深色专用页写死的 Color.white / Color.black，浅色外观下会和底色糊成一片。
/// 现在统一在这里给出「浅色一套 / 深色一套」，各视图只引用语义色。
///
/// 两点实现约束：
/// · NSColor 动态色跟随 NSApp 有效外观，不跟随 SwiftUI 局部 colorScheme override
///   （VaultStyle 里已经踩过这个坑），所以剪辑台刻意不加局部外观 override。
/// · Canvas / GraphicsContext 不保证传播 appearance，动态 NSColor 在离屏渲染里
///   可能解析到默认外观。Canvas 内的颜色改用 CanvasPalette 按 colorScheme 显式取色。
enum Theme {
    // MARK: 外观底色（原生语义色，自动适配浅色 / 深色）
    /// 浅色下刻意做成灰阶层次：窗口灰底 → 白面板 → 浅灰浮起卡，
    /// 三个层级拉开对比，避免"一片白没有区别"
    static let window = dynamic(NSColor(calibratedWhite: 0.93, alpha: 1),
                                NSColor(calibratedWhite: 0.067, alpha: 1))
    static let panel = dynamic(NSColor(calibratedWhite: 1, alpha: 1),
                               NSColor(calibratedWhite: 0.102, alpha: 1))
    static let raised = dynamic(NSColor(calibratedWhite: 0.97, alpha: 1),
                                NSColor(calibratedWhite: 0.145, alpha: 1))
    static let hover = dynamic(NSColor(calibratedWhite: 0.88, alpha: 1),
                               NSColor(calibratedWhite: 0.19, alpha: 1))
    static let border = Color(nsColor: .separatorColor)

    // MARK: 强调色 = 苹果系统主题色
    static let accent = Color(nsColor: .controlAccentColor)
    /// 未选中态的强调色（如素材池月份柱）。直接复用系统动态强调色，
    /// 不对其取 withAlphaComponent / 快照，保证用户换主题色时一起跟着变。
    static let accentMuted = Color(nsColor: .controlAccentColor).opacity(0.32)

    // MARK: 文字（原生 label 层级）
    static let text = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)

    // MARK: 内容色（时间线片段底，两种外观通用的深色卡 + 白字）
    static let videoClip = Color(red: 0.17, green: 0.30, blue: 0.40)
    static let musicClip = Color(red: 0.14, green: 0.34, blue: 0.27)
    static let subtitleClip = Color(red: 0.40, green: 0.29, blue: 0.14)
    static let textClip = Color(red: 0.36, green: 0.22, blue: 0.42)
    static let duckRange = Color(red: 0.55, green: 0.36, blue: 0.12)
    /// 播放头：浅色底上亮黄几乎看不见，换成高对比朱红；深色仍沿用亮黄。
    static let playhead = dynamic(NSColor(srgbRed: 0.90, green: 0.20, blue: 0.17, alpha: 1),
                                  NSColor(srgbRed: 1.0, green: 0.85, blue: 0.25, alpha: 1))

    // MARK: 时间线轨道底（按轨道类型分色）
    /// 浅色下比窗口灰底略深、且各带一点对应片段色的倾向；深色下比窗口底略亮。
    /// 这样每条轨道都是一条能一眼分辨的带子，而不是全靠 2.5% 白叠出来的同一片色。
    enum TrackKind { case text, main, duck, music, subtitle }

    private static let trackText = dynamic(NSColor(srgbRed: 0.885, green: 0.870, blue: 0.912, alpha: 1),
                                           NSColor(srgbRed: 0.145, green: 0.122, blue: 0.168, alpha: 1))
    private static let trackMain = dynamic(NSColor(srgbRed: 0.845, green: 0.878, blue: 0.912, alpha: 1),
                                           NSColor(srgbRed: 0.105, green: 0.136, blue: 0.168, alpha: 1))
    private static let trackDuck = dynamic(NSColor(srgbRed: 0.920, green: 0.878, blue: 0.836, alpha: 1),
                                           NSColor(srgbRed: 0.178, green: 0.136, blue: 0.096, alpha: 1))
    private static let trackMusic = dynamic(NSColor(srgbRed: 0.855, green: 0.903, blue: 0.868, alpha: 1),
                                            NSColor(srgbRed: 0.106, green: 0.162, blue: 0.122, alpha: 1))
    private static let trackSubtitle = dynamic(NSColor(srgbRed: 0.912, green: 0.886, blue: 0.850, alpha: 1),
                                               NSColor(srgbRed: 0.166, green: 0.140, blue: 0.100, alpha: 1))

    static func track(_ kind: TrackKind) -> Color {
        switch kind {
        case .text: return trackText
        case .main: return trackMain
        case .duck: return trackDuck
        case .music: return trackMusic
        case .subtitle: return trackSubtitle
        }
    }

    /// 轨道细边：把相邻轨道（以及轨道与窗口底）切干净。
    static let trackEdge = dynamic(NSColor(calibratedWhite: 0.62, alpha: 0.55),
                                   NSColor(calibratedWhite: 0, alpha: 0.55))
    /// 时间尺底色：和轨道区分开，浅色更亮、深色更深。
    static let ruler = dynamic(NSColor(calibratedWhite: 0.965, alpha: 1),
                               NSColor(calibratedWhite: 0.088, alpha: 1))

    // MARK: 时间线交互反馈
    /// 选中描边仍是白（深色片段底上最清楚），外面套一圈深色 halo，
    /// 于是浅色轨道底上也不会出现「白线画在白底上」。
    static let selection = Color.white
    static let selectionHalo = dynamic(NSColor(calibratedWhite: 0.14, alpha: 0.62),
                                       NSColor(calibratedWhite: 0, alpha: 0.80))
    /// 修剪手柄：浅色下白块本身会和浅轨道糊在一起，所以加一圈中灰边框 + 深色竖纹。
    static let trimHandle = dynamic(NSColor(calibratedWhite: 1, alpha: 1),
                                    NSColor(calibratedWhite: 0.94, alpha: 1))
    static let trimHandleBorder = dynamic(NSColor(calibratedWhite: 0.38, alpha: 0.95),
                                          NSColor(calibratedWhite: 0.12, alpha: 0.95))
    static let trimGrip = dynamic(NSColor(calibratedWhite: 0.22, alpha: 1),
                                  NSColor(calibratedWhite: 0.15, alpha: 1))
    /// 空轨道提示：tertiaryLabelColor 在浅色下太淡，单独给一个中灰。
    static let emptyHint = dynamic(NSColor(calibratedWhite: 0.46, alpha: 1),
                                   NSColor(calibratedWhite: 0.62, alpha: 1))
    /// 素材池刻度尺的年份分隔线 / 滚动指示条。
    static let gridLine = dynamic(NSColor(calibratedWhite: 0.55, alpha: 0.85),
                                  NSColor(calibratedWhite: 0.48, alpha: 0.85))
    static let scrollThumb = dynamic(NSColor(calibratedWhite: 0.42, alpha: 0.60),
                                     NSColor(calibratedWhite: 0.70, alpha: 0.55))
    /// 缩略图还没加载时的占位底。
    static let placeholder = dynamic(NSColor(calibratedWhite: 0.90, alpha: 1),
                                     NSColor(calibratedWhite: 0.16, alpha: 1))
    /// 文字样式预设卡模拟的是「画面」而不是面板：浅色下用中灰，深色下用深灰。
    static let previewTop = dynamic(NSColor(calibratedWhite: 0.58, alpha: 1),
                                    NSColor(calibratedWhite: 0.28, alpha: 1))
    static let previewBottom = dynamic(NSColor(calibratedWhite: 0.42, alpha: 1),
                                       NSColor(calibratedWhite: 0.16, alpha: 1))

    static let corner: CGFloat = 6

    /// 浅色一套 / 深色一套的动态色。
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            switch appearance.name {
            case .darkAqua, .vibrantDark,
                 .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark:
                return dark
            default:
                return light
            }
        })
    }
}

/// Canvas / GraphicsContext 里的颜色：动态 NSColor 走的是 NSApp 外观解析，
/// 离屏渲染时不保证拿到当前外观，这里按 SwiftUI colorScheme 显式给固定色。
enum CanvasPalette {
    static func tick(_ dark: Bool) -> Color { dark ? Color(white: 0.58) : Color(white: 0.40) }
    static func label(_ dark: Bool) -> Color { dark ? Color(white: 0.82) : Color(white: 0.22) }
    static func waveform(_ dark: Bool) -> Color { dark ? Color.white.opacity(0.45) : Color.white.opacity(0.62) }
    static func volume(_ dark: Bool) -> Color {
        dark ? Color(red: 1.0, green: 0.85, blue: 0.25) : Color.white.opacity(0.95)
    }
}

/// 面板小标题。
struct SectionTitle: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.secondary)
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 检查器参数行：标签 + 滑块 + 可编辑数值，全部压在一行里。
///
/// 属性栏原来每个参数都是「标签一行 + 滑块一行」，十几条排下来要滚很久，
/// 而且只能拖、没法精确输入。现在：
/// · 数值框可直接键入（按显示的单位输入即可，如 60% 打 `60`），回车或失焦提交、Esc 取消；
/// · 传入 resetValue 后，偏离默认值会显示强调色圆点，点圆点或双击标签即可复位；
/// · 拖动和键入都走 onEditing(true/false)，合并为一次撤销。
///
/// 数值反推不用给每个调用点补解析器：用 format(0) / format(1) 探测出
/// 「显示值 = 实际值 × scale + offset」，百分比、倍数、秒、千分字号都能自动还原。
struct LabeledSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String
    var onEditing: (Bool) -> Void
    var resetValue: Double?

    @State private var draft: String = ""
    @FocusState private var focused: Bool
    private let scale: Double
    private let offset: Double

    init(title: LocalizedStringKey,
         value: Binding<Double>,
         range: ClosedRange<Double>,
         format: @escaping (Double) -> String = { String(format: "%.0f", $0 * 100) },
         onEditing: @escaping (Bool) -> Void = { _ in },
         resetValue: Double? = nil) {
        self._value = value
        self.title = title
        self.range = range
        self.format = format
        self.onEditing = onEditing
        self.resetValue = resetValue
        _draft = State(initialValue: format(value.wrappedValue))
        let one = Self.firstNumber(format(1)) ?? 1
        let zero = Self.firstNumber(format(0)) ?? 0
        if abs(one - zero) > 0.000001 {
            self.scale = one - zero
            self.offset = zero
        } else {
            self.scale = 1
            self.offset = 0
        }
    }

    private var modified: Bool {
        guard let resetValue else { return false }
        return abs(value - resetValue) > 0.0001
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                if modified {
                    Button { reset() } label: {
                        Circle().fill(Theme.accent).frame(width: 5, height: 5)
                            .frame(width: 10, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("点击复位到默认值")
                } else {
                    Color.clear.frame(width: 10, height: 16)
                }
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            .frame(width: 72, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { reset() }
            .help("双击标签复位到默认值")

            Slider(value: $value, in: range, onEditingChanged: onEditing)
                .controlSize(.mini)
                .tint(Theme.accent)
                .frame(minWidth: 36)

            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 10.5).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .foregroundStyle(modified ? Theme.accent : Theme.text)
                .frame(width: 50)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(focused ? Theme.accent : Theme.border, lineWidth: 1))
                .focused($focused)
                .onSubmit { commit(); focused = false }
                .onExitCommand { draft = format(value); focused = false }
                .onChange(of: focused) { _, now in
                    if now {
                        // 进入编辑就全选，直接输数字覆盖，不用先手动删单位
                        DispatchQueue.main.async {
                            NSApp?.sendAction(NSSelectorFromString("selectAll:"), to: nil, from: nil)
                        }
                    } else {
                        commit()
                    }
                }
        }
        .frame(minHeight: 26)
        .onAppear { draft = format(value) }
        .onChange(of: value) { _, _ in
            if !focused { draft = format(value) }
        }
    }

    private func commit() {
        guard let shown = Self.firstNumber(draft) else { draft = format(value); return }
        let raw = (shown - offset) / scale
        let target = min(range.upperBound, max(range.lowerBound, raw))
        if abs(target - value) > 0.000001 {
            onEditing(true)
            value = target
            onEditing(false)
        }
        draft = format(target)
    }

    private func reset() {
        guard let resetValue else { return }
        let target = min(range.upperBound, max(range.lowerBound, resetValue))
        guard abs(target - value) > 0.000001 else { return }
        onEditing(true)
        value = target
        onEditing(false)
    }

    /// 从「100%」「1.00x」「1.0 秒」「+20」这类显示串里取第一个数字。
    private static func firstNumber(_ string: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"[-+]?\d+(?:\.\d+)?"#),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let range = Range(match.range, in: string) else { return nil }
        return Double(string[range].replacingOccurrences(of: "+", with: ""))
    }
}

/// 属性栏分组卡片：标题可折叠，折叠状态按 key 记住，右侧可挂「重置」等操作。
/// 把一长串滑块切成几张卡片，纵向短一大截，也更容易定位参数。
struct InspectorGroup<Content: View>: View {
    let title: LocalizedStringKey
    let key: String
    let defaultExpanded: Bool
    let actionTitle: LocalizedStringKey?
    let action: (() -> Void)?
    let content: () -> Content

    @State private var expanded: Bool

    init(_ title: LocalizedStringKey,
         key: String = "",
         defaultExpanded: Bool = true,
         actionTitle: LocalizedStringKey? = nil,
         action: (() -> Void)? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.key = key
        self.defaultExpanded = defaultExpanded
        self.actionTitle = actionTitle
        self.action = action
        self.content = content
        let stored = key.isEmpty ? nil : UserDefaults.standard.object(forKey: "inspector.group.\(key)") as? Bool
        _expanded = State(initialValue: stored ?? defaultExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 8)
                        Text(title).font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Theme.text)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 4)
                if let action, let actionTitle {
                    Button(actionTitle) { action() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            if expanded {
                VStack(alignment: .leading, spacing: 6) { content() }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .onChange(of: expanded) { _, now in
            guard !key.isEmpty else { return }
            UserDefaults.standard.set(now, forKey: "inspector.group.\(key)")
        }
    }
}

struct PanelButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(prominent ? Color.white : Theme.text)
            .background(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .fill(prominent ? Theme.accent : Theme.raised)
                    .opacity(configuration.isPressed ? 0.7 : 1)
            )
    }
}

extension View {
    /// SF Symbols 的部分图标（如 textformat）在中文环境下会换成汉字版本，图标统一用拉丁字母版本。
    func latinSymbol() -> some View { environment(\.locale, Locale(identifier: "en")) }

    func panelBackground() -> some View {
        background(Theme.panel).overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
    }

    /// 片段选中边框：白线 + 深色外圈。两种外观、以及深色片段底 / 浅色轨道底
    /// 上都能看清，不再只靠一条纯白 2pt 描边。
    func clipSelectionBorder(_ selected: Bool, radius: CGFloat) -> some View {
        self
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: radius)
                        .stroke(Theme.selectionHalo, lineWidth: 4)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(selected ? Theme.selection : Theme.border, lineWidth: selected ? 2 : 1)
            )
    }

    /// 叠在视频画面上的圆形缩放手柄：黑外圈 + 白内圈，亮画面 / 暗画面都不丢。
    func onContentHandleRing() -> some View {
        self
            .overlay(Circle().stroke(Color.black.opacity(0.55), lineWidth: 2.5))
            .overlay(Circle().stroke(Color.white, lineWidth: 1))
    }
}
