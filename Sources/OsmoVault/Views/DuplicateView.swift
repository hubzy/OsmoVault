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

// MARK: - 单条副本

private struct DuplicateRow: View {
    let asset: Asset
    let isKeeper: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isKeeper ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(isKeeper ? Color.green : Color.secondary)
                .help(isKeeper ? "保留" : "重复项")

            Text(abbreviate(asset.filePath))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(asset.filePath)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(ByteCountFormatter.string(fromByteCount: asset.fileSize, countStyle: .file))
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: asset.filePath)])
            } label: {
                Image(systemName: "arrow.right.circle").font(.caption)
            }
            .buttonStyle(.borderless)
            .help("在访达中显示")
            .accessibilityLabel(Text("在访达中显示"))

            Button(action: onRemove) {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.borderless)
            .help("从库中移除这一条")
            .accessibilityLabel(Text("从库中移除这一条"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
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

            VStack(spacing: 4) {
                ForEach(group) { asset in
                    DuplicateRow(asset: asset, isKeeper: asset.id == keeperID) {
                        if let id = asset.id { onRemove([id]) }
                    }
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
