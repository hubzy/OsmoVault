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

