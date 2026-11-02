import SwiftUI

/// 星级评分控件（点击设置，再点同星清除）
struct RatingControl: View {
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
    }
}

/// 颜色标签选择（无/红/橙/绿/蓝）
struct ColorLabelControl: View {
    let label: Int
    let onChange: (Int) -> Void
    static let colors: [Color?] = [nil, .red, .orange, .green, .blue]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<5, id: \.self) { i in
                Circle()
                    .fill(Self.colors[i] ?? Color.secondary.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .overlay(
                        Circle().stroke(label == i ? Color.primary : .clear, lineWidth: 2)
                    )
                    .onTapGesture { onChange(i) }
            }
        }
    }
}


/// 实况照片标记（LIVE）。
/// 按系统照片应用的规范：实况开启时显示 LIVE，关掉后显示带斜杠的图标，
/// 位置固定在画面**左上角**。compact 只留图标，给地图标记这类小尺寸用
struct LiveBadge: View {
    var enabled = true
    var playing = false
    /// 小尺寸场景（地图标记）只显示图标
    var compact = false
    /// 给了回调就可以点击切换实况开/关
    var action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(action: action) { label }
                    .buttonStyle(.plain)
                    .help(enabled ? "实况：开（点击关闭）" : "实况：关（点击开启）")
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
        .background(Capsule().fill(Color.black.opacity(playing ? 0.75 : 0.55)))
    }
}
