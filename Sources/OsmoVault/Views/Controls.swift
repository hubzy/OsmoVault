import SwiftUI

/// 详情区星级评分控件（点击设置，再点同星清除）。
/// 只在详情面板出现，可以用真 Button + 完整 help / VO；
/// 网格区 8000×5 星请用 `CompactRatingControl`（保持 onTapGesture，不引入 Button）。
struct RatingControl: View {
    let rating: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                let text = star == rating ? "清除评分" : "评为 \(star) 星"
                Button {
                    onChange(star == rating ? 0 : star)
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .foregroundStyle(star <= rating ? Color.yellow : Color.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(text)
                .accessibilityLabel(Text(text))
            }
        }
    }
}

/// 颜色标签选择（无/红/橙/绿/蓝）。只在详情出现，全部改成真 Button。
/// 注意：静态 `colors` 数组签名不能改，AssetGridView.swift 的色标引用了它。
struct ColorLabelControl: View {
    let label: Int
    let onChange: (Int) -> Void
    static let colors: [Color?] = [nil, .red, .orange, .green, .blue]
    private static let names = ["清除颜色标签", "颜色标签：红", "颜色标签：橙",
                                "颜色标签：绿", "颜色标签：蓝"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<5, id: \.self) { i in
                Button {
                    onChange(i)
                } label: {
                    Circle()
                        .fill(Self.colors[i] ?? Color.secondary.opacity(0.35))
                        .frame(width: 14, height: 14)
                        .overlay(
                            Circle().stroke(label == i ? Color.primary : .clear, lineWidth: 2)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Self.names[i])
                .accessibilityLabel(Text(Self.names[i]))
            }
        }
    }
}


/// 实况照片标记（LIVE）。
/// 按系统照片应用的规范：实况开启时显示 LIVE，关掉后显示带斜杠的图标，
/// 位置固定在画面**左上角**。compact 只留图标，给地图标记这类小尺寸用。
///
/// 这是**带 .help 的交互 Button、自带 Capsule 与黑白配色**，绝不套 VaultBadge
/// （VaultBadge 的强制白前景会覆盖它）。只复用 VaultBadge 的 alpha token。
struct LiveBadge: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var enabled = true
    var playing = false
    /// 小尺寸场景（地图标记）只显示图标
    var compact = false
    /// 给了回调就可以点击切换实况开/关
    var action: (() -> Void)?

    /// Reduce Transparency 不透明 / Increase Contrast 0.8 / 播放中 0.75 / 默认 0.65
    private var badgeOpacity: Double {
        if reduceTransparency { return 1.0 }
        if contrast == .increased { return 0.8 }
        return playing ? 0.75 : 0.65
    }

    var body: some View {
        Group {
            if let action {
                Button(action: action) { label }
                    .buttonStyle(.plain)
                    .help(enabled ? "实况：开（点击关闭）" : "实况：关（点击开启）")
                    .accessibilityLabel(Text(enabled ? "实况：开，点击关闭" : "实况：关，点击开启"))
            } else {
                label
                    .help(enabled ? "实况照片" : "实况已关闭")
            }
        }
    }

    private var label: some View {
        HStack(spacing: 3) {
            Image(systemName: enabled ? "livephoto" : "livephoto.slash")
                .font(.system(size: compact ? 9 : 11, weight: .semibold))
            if !compact {
                Text(enabled ? "LIVE" : "已关闭")
                    .font(.caption2)
                    .bold()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, compact ? 4 : 6)
        .padding(.vertical, compact ? 2 : 3)
        .background(Capsule().fill(Color.black.opacity(badgeOpacity)))
    }
}
