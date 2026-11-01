import SwiftUI
import AVFoundation

struct AssetGridView: View {
    let assets: [Asset]
    @Binding var selectedAssetID: Int64?
    var onRate: (Int64, Int) -> Void = { _, _ in }
    var onDelete: ((Int64) -> Void)?
    var onToggleFavorite: ((Int64) -> Void)?
    var emptyHint: String?
    /// 嵌入别的滚动容器（比如时间轴）时置 true：不再套自己的 ScrollView，避免双层滚动
    var embedded = false
    // 竖屏素材用更窄的最小宽度，让同屏能排下更多卡片
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 200), spacing: 14)] }

    var body: some View {
        Group {
            if embedded {
                LazyVGrid(columns: columns, spacing: 16) { cells }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) { cells }
                        .padding(16)
                }
                .overlay {
                    if assets.isEmpty { emptyState }
                }
            }
        }
    }

    @ViewBuilder
    private var cells: some View {
        ForEach(assets) { asset in
            AssetCell(asset: asset,
                      isSelected: selectedAssetID == asset.id,
                      onRate: { onRate(asset.id ?? 0, $0) },
                      onToggleFavorite: onToggleFavorite == nil ? nil : { onToggleFavorite?(asset.id ?? 0) })
                .contentShape(Rectangle())
                .onTapGesture { selectedAssetID = asset.id }
                .contextMenu {
                    Button(asset.isFavorite ? "取消收藏" : "收藏") {
                        onToggleFavorite?(asset.id ?? 0)
                    }
                    Button("移到回收站") { onDelete?(asset.id ?? 0) }
                }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(.secondary)
            Text(emptyHint ?? "还没有素材").font(.title3)
            if emptyHint == nil {
                Text("点击右上角导入文件夹开始建库").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// 独立出来的异步缩略图视图：出片面板等地方也能复用
struct AsyncThumbView: View {
    let asset: Asset
    @State private var thumb: NSImage?

    var body: some View {
        // 同样是弹性骨架 + overlay，避免 .fill 的固有宽高比撑破外框
        Color.clear
            .overlay {
                Group {
                    if let thumb {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.18))
                            .overlay { Image(systemName: "film").foregroundStyle(.tertiary) }
                    }
                }
            }
            .clipped()
            .task(id: asset.id) {
                guard thumb == nil else { return }
                thumb = await ThumbnailStore.shared.thumbnail(for: asset)
            }
    }
}

struct AssetCell: View {
    let asset: Asset
    let isSelected: Bool
    var onRate: (Int) -> Void = { _ in }
    var onToggleFavorite: (() -> Void)?

    /// hover 状态放在 cell 内部：放在父视图上会让每次移动鼠标都刷新整屏卡片
    @State private var isHovered = false
    @State private var previewOn = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var thumb: NSImage?

    /// 媒体区统一高度：横竖屏在同一行内等高显示，竖屏按比例变窄
    private var mediaHeight: CGFloat { 150 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            mediaArea
            infoArea
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            hoverTask?.cancel()
            if hovering {
                // 悬停 0.4s 才起播：鼠标扫过一排卡片时不会瞬间创建一堆 AVPlayer
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled else { return }
                    previewOn = true
                }
            } else {
                previewOn = false
            }
        }
        .onDisappear { hoverTask?.cancel() }
    }

    private var mediaArea: some View {
        ZStack(alignment: .bottomTrailing) {
            // 尺寸骨架必须是弹性的 Color.clear：
            // .fill 的图片带固有宽高比，直接放进 ZStack 会把卡片撑得比列宽还宽，
            // 列间距和四周 padding 会被吃掉。overlay 内容不参与尺寸计算，只负责画面。
            Color.clear
                .overlay {
                    ZStack {
                        if let thumb {
                            Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle()
                                .fill(Color.gray.opacity(0.18))
                                .overlay { Image(systemName: "film").font(.largeTitle).foregroundStyle(.tertiary) }
                        }
                        // 缩略图垫底 + 播放器叠加：首帧解码前不闪黑
                        if previewOn {
                            HoverPreviewPlayer(url: URL(fileURLWithPath: asset.filePath))
                        }
                    }
                }
                .frame(height: mediaHeight)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                )

            Text(Self.durationText(asset.durationSeconds))
                .font(.caption2).monospacedDigit()
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
                .padding(6)
        }
        .overlay(alignment: .topTrailing) {
            if asset.isFavorite || (isHovered && onToggleFavorite != nil) {
                Button {
                    onToggleFavorite?()
                } label: {
                    Image(systemName: asset.isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(asset.isFavorite ? .pink : .white)
                        .shadow(radius: 2)
                }
                .buttonStyle(.plain)
                .padding(6)
            }
        }
        .overlay(alignment: .topLeading) {
            if isHovered && previewOn {
                Image(systemName: "play.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(6)
            }
        }
        .task(id: asset.id) {
            guard thumb == nil else { return }
            thumb = await ThumbnailStore.shared.thumbnail(for: asset)
        }
    }

    private var infoArea: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if asset.colorLabel > 0 {
                    Circle().fill(ColorLabelControl.colors[asset.colorLabel] ?? .clear)
                        .frame(width: 8, height: 8)
                }
                Text(asset.fileName).font(.footnote).lineLimit(1)
            }
            HStack(spacing: 6) {
                if let t = asset.recordedAt {
                    Text(t, style: .date).font(.caption2).foregroundStyle(.secondary)
                }
                if asset.latitude != nil {
                    Image(systemName: "mappin").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                RatingControl(rating: asset.rating, onChange: onRate)
                    .controlSize(.mini)
            }
        }
    }

    static func durationText(_ s: Double) -> String {
        let total = Int(s.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
