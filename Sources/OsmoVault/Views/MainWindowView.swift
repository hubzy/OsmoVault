import SwiftUI
import AVFoundation

struct MainWindowView: View {
    @EnvironmentObject var appModel: AppModel
    @State private var showImporter = false
    @State private var selectedAssetID: Int64?
    @State private var section: SidebarItem? = .library
    @State private var grabStatus: String?
    @State private var playerController = PlayerController()

    /// 统一按 id 取最新素材：库重载后详情不会停留在旧副本上
    private var selectedAsset: Asset? {
        guard let id = selectedAssetID else { return nil }
        return appModel.assets.first { $0.id == id }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                SidebarHeaderView(roots: appModel.libraryRoots, assetCount: appModel.assets.count)
                Divider()
                SidebarView(selection: $section, assets: appModel.assets)
            }
        } content: {
            mainContent
                .navigationSplitViewColumnWidth(min: 380, ideal: 560, max: 1200)
        } detail: {
            detailContent
                .navigationSplitViewColumnWidth(min: 320, ideal: 460)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showImporter = true
                } label: {
                    Label("导入文件夹", systemImage: "plus.square.on.square")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    grabFrame()
                } label: {
                    Label("截取实况图 (S)", systemImage: "camera.shutter.button")
                }
                .disabled(selectedAsset == nil)
                .keyboardShortcut("s", modifiers: [])
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let folder = urls.first {
                appModel.scanFolder(folder)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 6) {
                if appModel.isScanning, let p = appModel.scanProgress {
                    ScanStatusBar(progress: p)
                }
                if let msg = grabStatus {
                    Text(msg)
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: - 主内容区

    @ViewBuilder
    private var mainContent: some View {
        switch section {
        case .trash:
            TrashView()
        case .quickCut:
            QuickCutPanel()
        case .timeline:
            TimelineView(assets: appModel.assets, selectedAssetID: $selectedAssetID,
                         onRate: { appModel.setRating(id: $0, rating: $1) },
                         onDelete: deleteAsset,
                         onToggleFavorite: { appModel.toggleFavorite(id: $0) })
        case .map:
            MapView(assets: appModel.assets, selectedAssetID: $selectedAssetID)
        case .smartAlbum(let id):
            if let album = SmartAlbum.find(id: id) {
                grid(album.filter(appModel.assets), hint: "「\(album.name)」里还没有素材")
            } else {
                placeholder("相册不存在")
            }
        case .place(let name):
            grid(appModel.assets.filter { $0.placeName == name }, hint: nil)
        default:
            grid(appModel.assets, hint: nil)
        }
    }

    private func grid(_ assets: [Asset], hint: String?) -> some View {
        AssetGridView(assets: assets, selectedAssetID: $selectedAssetID,
                      onRate: { appModel.setRating(id: $0, rating: $1) },
                      onDelete: deleteAsset,
                      onToggleFavorite: { appModel.toggleFavorite(id: $0) },
                      emptyHint: hint)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }

    // MARK: - 详情区

    @ViewBuilder
    private var detailContent: some View {
        if let asset = selectedAsset {
            AssetDetailView(
                asset: asset,
                controller: playerController,
                onRate: { appModel.setRating(id: $0, rating: $1) },
                onColor: { appModel.setColorLabel(id: $0, label: $1) },
                onToggleFavorite: { appModel.toggleFavorite(id: asset.id ?? 0) },
                onGrab: grabFrame
            )
            .onAppear { load(asset) }
            .onChange(of: asset.id) { _, _ in
                if let a = selectedAsset { load(a) }
            }
        } else {
            Text("选择素材查看详情")
                .foregroundStyle(.secondary)
        }
    }

    private func load(_ asset: Asset) {
        playerController.load(url: URL(fileURLWithPath: asset.filePath))
    }

    // MARK: - 操作

    private func deleteAsset(_ id: Int64) {
        if selectedAssetID == id { selectedAssetID = nil }
        appModel.moveToTrash(id: id)
    }

    private func grabFrame() {
        guard let asset = selectedAsset else { return }
        let seconds = playerController.currentTime
        do {
            let url = try FrameGrabService.grab(asset: asset, at: seconds)
            grabStatus = "已保存实况图：\(url.lastPathComponent)"
        } catch {
            grabStatus = "截取失败：\(error.localizedDescription)"
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            grabStatus = nil
        }
    }
}

struct ScanStatusBar: View {
    let progress: ScanProgress
    var body: some View {
        switch progress.state {
        case .discovering:
            Label("正在发现文件…", systemImage: "magnifyingglass").padding(8).background(.bar, in: RoundedRectangle(cornerRadius: 8))
        case .importing(let indexed, let total):
            HStack {
                if let total {
                    ProgressView(value: Double(indexed) / Double(max(total, 1)))
                } else {
                    ProgressView()
                }
                Text(progress.currentFile ?? "").lineLimit(1).font(.caption).foregroundStyle(.secondary)
            }.padding(8).frame(maxWidth: 420).background(.bar, in: RoundedRectangle(cornerRadius: 8))
        case .finished(let newAssets, let duplicates):
            Label("完成：新增 \(newAssets)，跳过重复 \(duplicates)", systemImage: "checkmark.circle").padding(8).background(.bar, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
