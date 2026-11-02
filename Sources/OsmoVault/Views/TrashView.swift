import SwiftUI

/// 回收站：与图库一致的卡片预览 + 恢复 / 彻底删除。
/// 「清空」分两档：连磁盘文件一起删（不可恢复），或只丢索引保留文件
struct TrashView: View {
    @EnvironmentObject var appModel: AppModel
    @State private var deletedAssets: [Asset] = []
    @State private var confirmEmpty = false
    @State private var confirmSingle: Asset?
    @State private var isWorking = false
    @State private var status: String?

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 180), spacing: 14)] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear(perform: reload)
        .confirmationDialog("清空回收站", isPresented: $confirmEmpty) {
            Button("删除文件并清空（不可恢复）", role: .destructive) { empty(deleteFiles: true) }
            Button("只从库中移除（保留文件）") { empty(deleteFiles: false) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("回收站共 \(deletedAssets.count) 条。删除文件会把原文件从磁盘抹掉，无法撤销。")
        }
        .confirmationDialog("彻底删除", isPresented: Binding(
            get: { confirmSingle != nil },
            set: { if !$0 { confirmSingle = nil } }
        )) {
            Button("删除文件（不可恢复）", role: .destructive) {
                if let a = confirmSingle { purge(a, deleteFile: true) }
            }
            Button("只从库中移除（保留文件）") {
                if let a = confirmSingle { purge(a, deleteFile: false) }
            }
            Button("取消", role: .cancel) { confirmSingle = nil }
        } message: {
            Text(confirmSingle.map { "「\($0.fileName)」将从磁盘删除，无法撤销。" } ?? "")
        }
        .overlay(alignment: .bottom) {
            if let status {
                Text(status)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 10)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("回收站").font(.title2).bold()
                Text("\(deletedAssets.count) 个素材 · 恢复后回到图库，彻底删除会抹掉磁盘上的原文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("回收站里的素材不参与图库统计，也不进一键出片的素材池")
            }
            Spacer(minLength: 0)
            Button(role: .destructive) {
                confirmEmpty = true
            } label: {
                Label("清空回收站", systemImage: "trash.fill")
            }
            .disabled(deletedAssets.isEmpty || isWorking)
            .help("清空回收站里的全部素材")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if deletedAssets.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "trash").font(.largeTitle).foregroundStyle(.secondary)
                Text("回收站是空的").font(.title3)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(deletedAssets) { asset in
                        TrashCard(asset: asset,
                                  onRestore: { restore(asset) },
                                  onPurge: { confirmSingle = asset })
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - 操作

    private func reload() {
        deletedAssets = (try? appModel.database.readDeletedAssets()) ?? []
    }

    private func restore(_ a: Asset) {
        appModel.restore(id: a.id ?? 0)
        reload()
    }

    private func purge(_ a: Asset, deleteFile: Bool) {
        confirmSingle = nil
        isWorking = true
        Task {
            await appModel.purge(a, deleteFile: deleteFile)
            reload()
            isWorking = false
            flash(deleteFile ? "已删除文件：\(a.fileName)" : "已从库中移除：\(a.fileName)")
        }
    }

    private func empty(deleteFiles: Bool) {
        isWorking = true
        Task {
            let n = await appModel.emptyTrash(deleteFiles: deleteFiles)
            reload()
            isWorking = false
            flash(deleteFiles ? "已彻底删除 \(n) 个文件" : "已从库中移除 \(n) 条记录（文件保留）")
        }
    }

    private func flash(_ text: String) {
        status = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            status = nil
        }
    }
}

/// 回收站卡片：缩略图 + 文件名 + 路径 + 恢复/删除。
/// 预览复用图库那条缩略图通道（内存/磁盘缓存），滚到才解码
private struct TrashCard: View {
    let asset: Asset
    var onRestore: () -> Void
    var onPurge: () -> Void

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
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )

                HStack(spacing: 4) {
                    Image(systemName: asset.kind == .video ? "video.fill"
                          : asset.kind == .livePhoto ? "livephoto" : "photo")
                        .font(.caption2)
                        .foregroundStyle(.white)
                    if asset.kind != .photo {
                        Text(AssetCell.durationText(asset.durationSeconds))
                            .font(.caption2).monospacedDigit()
                            .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                if isHovered {
                    Button(action: onPurge) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                    }
                    .buttonStyle(.plain)
                    .help("彻底删除")
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

            HStack(spacing: 8) {
                Button("恢复", action: onRestore)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("删除") { onPurge() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .onHover { isHovered = $0 }
    }

    private static func readableSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
}
