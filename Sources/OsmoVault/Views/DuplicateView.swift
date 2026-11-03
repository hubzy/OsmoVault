import SwiftUI
import AppKit

/// 重复素材：同一段视频被从两个不同路径导入后的清理入口。
/// 判定依据 = 文件大小 + 时长（毫秒级），比 fileHash（含 mtime）可靠——
/// 拷贝出来的副本 mtime 是新的，但字节数和时长必然一致。
struct DuplicateView: View {
    @EnvironmentObject var appModel: AppModel

    @State private var pendingIDs: [Int64] = []
    @State private var showConfirm = false

    private var groups: [[Asset]] { appModel.duplicateGroups() }

    private var redundantCount: Int {
        groups.reduce(0) { $0 + appModel.redundantIDs(in: $1).count }
    }

    var body: some View {
        VStack(spacing: 0) {
            if groups.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("没有发现重复素材").font(.title3)
                    Text("同一段视频从两个文件夹各导入一次时，会出现在这里")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                header
                Divider()
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(groups, id: \.self.first?.id) { group in
                            GroupCard(group: group) { ids in
                                pendingIDs = ids
                                showConfirm = true
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .alert("确认移除", isPresented: $showConfirm) {
            Button("移除 \(pendingIDs.count) 条", role: .destructive) {
                appModel.removeAssets(ids: pendingIDs)
                pendingIDs = []
            }
            Button("取消", role: .cancel) { pendingIDs = [] }
        } message: {
            Text("将移除 \(pendingIDs.count) 条索引记录；磁盘文件保留，但评分、颜色标签、收藏和手动补的定位会一并清除且无法恢复")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(groups.count) 组重复 · 可清理 \(redundantCount) 条")
                    .font(.headline)
                Text("每组默认保留最早导入的那一个")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                pendingIDs = groups.flatMap { appModel.redundantIDs(in: $0) }
                showConfirm = true
            } label: {
                Label("清理全部重复", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("移除全部重复索引记录，磁盘文件保留")
            .disabled(redundantCount == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - 单条副本卡片

/// 重复素材的一个副本：缩略图 + 文件名 + 路径 + 大小。
/// 预览复用图库那条缩略图通道（内存/磁盘缓存），滚到才解码
private struct DuplicateCard: View {
    let asset: Asset
    let isKeeper: Bool
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                // 弹性骨架 + overlay：图片的固有宽高比不会撑破列宽
                Color.clear
                    .overlay { AsyncThumbView(asset: asset) }
                    .frame(height: 130)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )

                VaultBadge {
                    HStack(spacing: 4) {
                        Image(systemName: asset.kind == .video ? "video.fill"
                              : asset.kind == .livePhoto ? "livephoto" : "photo")
                            .font(.caption2)
                        if asset.kind != .photo {
                            Text(AssetCell.durationText(asset.durationSeconds))
                        }
                    }
                }
                .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                if isKeeper {
                    // 保留项常驻一个绿色角标：同一屏里一眼看出留谁
                    Label("保留", systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.green, in: Capsule())
                        .shadow(radius: 1)
                        .padding(6)
                } else if isHovered {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                    }
                    .buttonStyle(.plain)
                    .help("从库中移除这一条")
                    .accessibilityLabel(Text("从库中移除这一条"))
                    .padding(6)
                }
            }

            Text(asset.fileName)
                .font(.footnote)
                .lineLimit(1)
                .help(asset.filePath)
            Text(Self.readableSize(asset.fileSize))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(abbreviate(asset.filePath))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(asset.filePath)

            HStack(spacing: 8) {
                if isKeeper {
                    Text("最早导入 · 保留")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("移除此条", role: .destructive) { onRemove() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: asset.filePath)])
                } label: {
                    Image(systemName: "arrow.right.circle").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("在访达中显示")
                .accessibilityLabel(Text("在访达中显示"))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .onHover { isHovered = $0 }
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private static func readableSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
}

// MARK: - 单组

private struct GroupCard: View {
    @EnvironmentObject var appModel: AppModel
    let group: [Asset]
    let onRemove: ([Int64]) -> Void

    private var keeperID: Int64? {
        group.min(by: { $0.createdAt < $1.createdAt })?.id
    }

    private var redundant: [Int64] { appModel.redundantIDs(in: group) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
                Text(group.first?.fileName ?? "")
                    .font(.callout.bold())
                    .lineLimit(1)
                Text("\(group.count) 个副本")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    onRemove(redundant)
                } label: {
                    Text("保留最早，移除其余 \(redundant.count) 个")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("移除该组多余索引记录，磁盘文件保留")
                .disabled(redundant.isEmpty)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)],
                      alignment: .leading, spacing: 10) {
                ForEach(group) { asset in
                    DuplicateCard(asset: asset, isKeeper: asset.id == keeperID) {
                        if let id = asset.id { onRemove([id]) }
                    }
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
