import SwiftUI
import AppKit

// MARK: - 设计 Token 与分级
//
// macOS 15 没有系统液态玻璃视图 API（那是后续系统版本才提供的），这里不引入任何私有 API。
// 玻璃材质只用于「容器 / 浮层」语言；按钮本体一律回归系统控件，否则
// pressed / disabled / focus 三态会被半透明背景糊掉，键盘焦点也看不出来。
//
//   L1  .borderedProminent                             每屏唯一的主操作
//   L2  .bordered + .controlSize(.small)              常规次级操作 / 中性二次确认
//   L3  .bordered + role: .destructive + small       不可逆的用户数据丢失，必须二次确认
//   L4  VaultIconButton                              **常驻**无文字图标按钮（.borderless 系统三态）
//   L5  VaultGlassContainer                          大面积浮层 / 控制条外壳（纯背景，不烘焙前景色）
//   L6  VaultBadge                                   只读状态徽章（Capsule），绝不包交互按钮
//
// 破坏性语义按「用户数据能否完整重建」分级，不搞一刀切：
//   · moveToTrash（只置 isDeleted 标记，行与元数据全留）＝ 可恢复
//       → 单条：中性 + Toast；批量：中性 + 中性 confirmationDialog
//   · removeAssets / removeSource（删整行，评分 / 颜色标签 / 收藏 / 手动定位重扫不回来）
//       → L3 红 + 确认
//   · purge / emptyTrash（连磁盘文件一起删）→ L3 红 + 确认
//   · 清空手调片段 / 清除手动定位（不可重建）→ L3 红 + 确认

enum Vault {
    /// 四档圆角：6 / 8 / 10 / 14。
    /// `focusRing` 是焦点环半径，不是第五档圆角。
    enum R {
        static let control: CGFloat = 6
        static let media: CGFloat = 8
        static let card: CGFloat = 10
        static let container: CGFloat = 14
        static let focusRing: CGFloat = 10
    }

    /// 全项目统一的 continuous 圆角（比默认 .circular 更贴近系统连续曲率）
    static func shape(_ radius: CGFloat = R.container) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    enum S {
        static let tight: CGFloat = 4
        static let compact: CGFloat = 6
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let wide: CGFloat = 20
    }

    /// 常驻图标按钮的最小命中区（HIG 建议 ≥ 24pt，这里给 28；密集控制条传 26）
    static let iconHit: CGFloat = 28

    static func hairline(dark: Bool) -> Color {
        Color.primary.opacity(dark ? 0.12 : 0.08)
    }
}

// MARK: - L5 玻璃外壳（纯背景装饰，绝不烘焙文字颜色）

///大面积浮层外壳：14pt continuous 大圆角 + regularMaterial + 1px 发丝描边 + 轻阴影。
///
/// 这是**纯背景**组件：不写任何 `.foregroundStyle`，文字 / 图标颜色完全交给调用方。
/// 因此 TheaterView 的 `.environment(\.colorScheme, .dark)` 与 `.foregroundStyle(.white)`
/// 一个字都不用改。
///
/// 辅助功能两条分支：
/// · Reduce Transparency → 去掉 Material，用 SwiftUI 语义 `.fill(.background)`。
///   **不能**用 `Color(nsColor: .windowBackgroundColor)`：NSColor 动态色跟随 NSApp 有效外观，
///   不跟随 SwiftUI 局部 colorScheme override，浅色主题全屏下会变浅底 + 白字。
/// · Increase Contrast  → 描边加深到 0.35、阴影改 `Color.clear`（描边加深 + 阴影消失）。
///
/// **玻璃层自身不带任何 animation**：TheaterView 控制条的 2.5s 淡出由外层
/// `.animation(..., value: controlsVisible)` 驱动，插拔动画也由外层 `.transition` 驱动。
///
/// 命中测试：背景层与 1px 描边 Shape 都 `.allowsHitTesting(false)`，只加在装饰 Shape 上。
/// SwiftUI 的 Shape 按**整个圆角矩形 path** 参与命中测试（不是只有那条线），overlay 又在
/// content 上层，不禁用会整片挡住按钮 / Slider（尤其 TheaterView 的进度条）。
struct VaultGlassContainer<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    var radius: CGFloat = Vault.R.container
    var padding: CGFloat = Vault.S.medium
    var material: Material = .regularMaterial
    @ViewBuilder var content: () -> Content

    init(radius: CGFloat = Vault.R.container,
         padding: CGFloat = Vault.S.medium,
         material: Material = .regularMaterial,
         @ViewBuilder content: @escaping () -> Content) {
        self.radius = radius
        self.padding = padding
        self.material = material
        self.content = content
    }

    private var dark: Bool { colorScheme == .dark }

    /// 描边只用 SwiftUI 语义色，避免 NSColor 动态色不跟随局部 colorScheme override
    private var strokeColor: Color {
        if contrast == .increased { return Color.primary.opacity(0.35) }
        if reduceTransparency { return Color.primary.opacity(0.20) }
        return Vault.hairline(dark: dark)
    }

    private var shadowColor: Color {
        if contrast == .increased { return .clear }
        return Color.black.opacity(dark ? 0.35 : 0.12)
    }

    var body: some View {
        content()
            .padding(padding)
            .background {
                glass
                    .allowsHitTesting(false)   // 背景装饰层：content 里的按钮 / Slider 照常可点可拖
            }
            // 不在这里写容器级 .contentShape：它会把含 12pt padding 的整块圆角矩形
            // 定义成命中区，上层浮层会吞掉下层网格卡片 / 地图标记 / 全屏画面的点击。
            // 背景层与 1px 描边已各自用 Vault.shape 定义过形状，容器级 contentShape 是多余的。
    }

    @ViewBuilder
    private var glass: some View {
        let shape = Vault.shape(radius)
        Group {
            if reduceTransparency {
                shape.fill(.background)
            } else {
                shape.fill(material)
            }
        }
        .shadow(color: shadowColor, radius: 10, y: 3)
        .overlay {
            shape.strokeBorder(strokeColor, lineWidth: 1)
                .allowsHitTesting(false)   // 必修：装饰 Shape 不参与命中
        }
    }
}

// MARK: - L4 常驻图标按钮

///图标按钮：内部仍是 `.borderless` 系统按钮，pressed / disabled / focus ring 由系统负责。
///
/// **适用面仅限常驻图标按钮**。hover-only 按钮（TrashCard 悬浮 xmark、AssetCell 悬浮心形）
/// 不要套它：组件自带 `.help` + `.accessibilityLabel`，会把 8000 个 cell 塞进 VO 与 Tab 顺序；
/// 那些按钮直接 `.accessibilityHidden(true)` 即可。
///
/// `tint` 只用于状态色（例如「循环已开启」），不要拿它表达破坏性操作。
struct VaultIconButton: View {
    let label: String
    let systemImage: String
    var tint: Color? = nil
    var symbolSize: CGFloat = 14
    var hit: CGFloat = Vault.iconHit
    var isDisabled = false
    let action: () -> Void

    init(_ label: String,
         systemImage: String,
         tint: Color? = nil,
         symbolSize: CGFloat = 14,
         hit: CGFloat = Vault.iconHit,
         isDisabled: Bool = false,
         action: @escaping () -> Void) {
        self.label = label
        self.systemImage = systemImage
        self.tint = tint
        self.symbolSize = symbolSize
        self.hit = hit
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Group {
            if let tint {
                core.foregroundStyle(tint)
            } else {
                // tint 为 nil 时不写 foregroundStyle，保留父视图的 .white / 动态色
                core
            }
        }
        .help(label)
        .accessibilityLabel(Text(label))
        .disabled(isDisabled)
    }

    private var core: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: symbolSize))
                // label 内也铺满 hit×hit，保证 28×28 四个边角整片可响应
                .frame(width: hit, height: hit)
                .contentShape(Vault.shape(Vault.R.control))
        }
        .buttonStyle(.borderless)
        // .borderless 自带 inset 会撑出去，Button 外框也要约束一次。
        // 密集控制条（TransportBar）传 hit: 26，保住 >360 / 300~360 / <300 三档宽度降级阈值
        .frame(width: hit, height: hit)
    }
}

// MARK: - L6 只读状态徽章

///只读状态徽章：Capsule + 深色底 + 白字 + 等宽数字。
/// **只包纯展示徽章**（时长、聚合计数）；绝不包 LiveBadge —— 后者是带 `.help` 的交互
/// Button、自己已有 Capsule 与黑白配色，这里的强制白前景会把它毁掉。
///
/// 黑底 alpha 三档：Reduce Transparency 1.0 / Increase Contrast 0.80 / 默认 0.65。
struct VaultBadge<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var horizontal: CGFloat = 5
    var vertical: CGFloat = 2
    var font: Font = .caption2.monospacedDigit()
    @ViewBuilder var content: () -> Content

    init(horizontal: CGFloat = 5,
         vertical: CGFloat = 2,
         font: Font = .caption2.monospacedDigit(),
         @ViewBuilder content: @escaping () -> Content) {
        self.horizontal = horizontal
        self.vertical = vertical
        self.font = font
        self.content = content
    }

    private var fill: Color {
        if reduceTransparency { return .black }
        if contrast == .increased { return Color.black.opacity(0.8) }
        return Color.black.opacity(0.65)
    }

    var body: some View {
        content()
            .font(font)
            .foregroundStyle(.white)
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .background(Capsule().fill(fill))
    }
}

// MARK: - 功能区按钮样式（只管 hover / pressed / disabled / fill / 1px 描边）

/// **不碰焦点**：可聚焦元素是外层 `Button`，焦点环由 `ActionItem` 用 `@FocusState` +
/// `.focused($focused)` 挂到 Button 上自绘。挂在 ButtonStyle 返回的 label 容器上，
/// FKA 下 binding 可能永远不翻、环不出现。
struct VaultActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        VaultActionSurface(configuration: configuration)
    }
}

private struct VaultActionSurface: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    private var fill: Color {
        if configuration.isPressed { return Color.primary.opacity(0.18) }
        if hovering { return Color.primary.opacity(0.10) }
        return Color.primary.opacity(0.05)
    }

    var body: some View {
        configuration.label
            .background { Vault.shape(Vault.R.control).fill(fill) }
            .overlay {
                Vault.shape(Vault.R.control)
                    .strokeBorder(Vault.hairline(dark: colorScheme == .dark), lineWidth: 1)
                    .allowsHitTesting(false)   // 必修：1px 装饰描边不挡点击
            }
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .onHover { hovering = $0 }
    }
}

// MARK: - 网格区紧凑评分控件（不引入 Button）

/// 8000×5 星的高密度网格里**绝不能**塞 5×N 个 Button：保留 `onTapGesture`，
/// 整组作为一个可访问性元素，用 adjustable action 提供键盘 / VO 等价路径。
/// 点击语义与详情区一致：`star == rating` 时再点同星清除评分。
struct CompactRatingControl: View {
    let rating: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .foregroundStyle(star <= rating ? Color.yellow : Color.secondary)
                    .onTapGesture { onChange(star == rating ? 0 : star) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("评分"))
        .accessibilityValue(rating == 0 ? Text("未评分") : Text("\(rating) 星"))
        .accessibilityAdjustableAction { direction in
            onChange(direction == .increment ? min(rating + 1, 5) : max(rating - 1, 0))
        }
    }
}
