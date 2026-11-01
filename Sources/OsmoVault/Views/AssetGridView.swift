import SwiftUI
import AVFoundation

struct AssetGridView: View {
    let assets: [Asset]
    @Binding var selectedAsset: Asset?
    var onRate: (Int64, Int) -> Void = { _, _ in }
    var onColor: (Int64, Int) -> Void = { _, _ in }
    var onDelete: ((Int64) -> Void)?
    @State private var hoveredAssetID: Int64?
    // 竖屏素材用更窄的最小宽度，让同屏能排下更多卡片
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 200), spacing: 14)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(assets) { asset in
                    AssetCell(asset: asset,
                              isHovered: hoveredAssetID == asset.id,
                              isSelected: selectedAsset?.id == asset.id,
                              onRate: { onRate(asset.id ?? 0, $0) },
                              onColor: { onColor(asset.id ?? 0, $0) })
                        .onHover { hovering in
                            hoveredAssetID = hovering ? asset.id : nil
                        }
                        .onTapGesture { selectedAsset = asset }
                        .contextMenu {
                            Button("移到回收站") { onDelete?(asset.id ?? 0) }
                        }
                }
            }
            .padding(16)
        }
        .padding(.horizontal, 0)
        .overlay {
            if assets.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(.secondary)
                    Text("还没有素材").font(.title3)
                    Text("点击右上角导入文件夹开始建库").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct AssetCell: View {
    let asset: Asset
    let isHovered: Bool
    let isSelected: Bool
    @State private var thumb: NSImage?
    var onRate: (Int) -> Void = { _ in }
    var onColor: (Int) -> Void = { _ in }

    /// 媒体区统一高度：横竖屏在同一行内等高显示，竖屏按比例变窄
    private var mediaHeight: CGFloat { 150 }
    private var videoRatio: CGFloat {
        let w = CGFloat(asset.width), h = CGFloat(asset.height)
        guard w > 0, h > 0 else { return 16.0 / 9.0 }
        return w / h
    }
    private var isPortrait: Bool { videoRatio < 0.95 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                mediaArea
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
                    .padding(6)
            }
            infoArea
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var mediaArea: some View {
        Color.clear
            .overlay {
                if isHovered {
                    // 缩略图垫底 + 播放器叠加：首帧解码前不闪黑
                    ZStack {
                        if let thumb {
                            Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.black
                        }
                        HoverPreviewPlayer(url: URL(fileURLWithPath: asset.filePath))
                    }
                } else if let thumb {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .overlay { Image(systemName: "film").font(.largeTitle).foregroundStyle(.tertiary) }
                        .task { thumb = ThumbnailStore.shared.thumbnail(for: asset) }
                }
            }
            .clipped()
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
                if let lat = asset.latitude {
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

