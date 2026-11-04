import AppKit
import SwiftUI

/// 主题：跟随 macOS 原生外观（浅色 / 深色自动切换）。
///
/// 底色、文字、分隔线全部用系统语义色，强调色用系统主题色
/// （controlAccentColor，随用户在「系统设置 → 外观」里选的颜色走）。
/// 片段色是内容色（时间线卡片底），两种外观下都够对比，保持不变。
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

    // MARK: 文字（原生 label 层级）
    static let text = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)

    // MARK: 内容色（时间线片段底、播放头等，两种外观通用）
    static let videoClip = Color(red: 0.17, green: 0.30, blue: 0.40)
    static let musicClip = Color(red: 0.14, green: 0.34, blue: 0.27)
    static let subtitleClip = Color(red: 0.40, green: 0.29, blue: 0.14)
    static let textClip = Color(red: 0.36, green: 0.22, blue: 0.42)
    static let duckRange = Color(red: 0.55, green: 0.36, blue: 0.12)
    static let playhead = Color(red: 1.0, green: 0.85, blue: 0.25)

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

/// 带标签与数值的滑块，拖动期间合并为一次撤销。
struct LabeledSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.0f", $0 * 100) }
    var onEditing: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12)).foregroundStyle(Theme.text)
                Spacer()
                Text(format(value)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondary)
            }
            Slider(value: $value, in: range, onEditingChanged: onEditing)
                .controlSize(.small)
                .tint(Theme.accent)
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
}
