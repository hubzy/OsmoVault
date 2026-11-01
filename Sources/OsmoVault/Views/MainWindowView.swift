import SwiftUI
import AVFoundation

struct MainWindowView: View {
    @EnvironmentObject var appModel: AppModel
    @State private var showImporter = false
    @State private var selectedAsset: Asset?
    @State private var section: SidebarView.Section? = .library
    @State private var grabStatus: String?
    @State private var playerController = PlayerController()

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $section)
        } content: {
            mainContent
        } detail: {
            detailContent
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
            if appModel.isScanning, let p = appModel.scanProgress {
                ScanStatusBar(progress: p)
            }
            if let msg = grabStatus {
                Text(msg)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        switch section {
        case .trash:
            TrashView()
        case .quickCut:
            QuickCutPanel(seedAssets: selectedAssetsForCut)
        case .timeline:
            TimelineView(assets: appModel.assets, selectedAsset: $selectedAsset,
                         onRate: updateRating, onColor: updateColor)
        case .map:
            MapView(assets: appModel.assets, selectedAsset: $selectedAsset)
        default:
            AssetGridView(assets: appModel.assets, selectedAsset: $selectedAsset,
                          onRate: updateRating, onColor: updateColor,
                          onDelete: deleteAsset)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let asset = selectedAsset {
            AssetDetailView(asset: asset, controller: playerController,
                            onRate: updateRating, onColor: updateColor)
                .onAppear { playerController.load(url: URL(fileURLWithPath: asset.filePath)) }
                .onChange(of: selectedAsset?.id) { newID in
                    if let a = appModel.assets.first(where: { $0.id == newID }) {
                        playerController.load(url: URL(fileURLWithPath: a.filePath))
                    }
                }
        } else {
            Text("选择素材查看详情")
                .foregroundStyle(.secondary)
        }
    }

    private func updateRating(_ id: Int64, _ rating: Int) {
        try? appModel.database.updateRating(id: id, rating: rating)
        appModel.reloadAssets()
    }

    /// 出片段池：有选中素材用选中的，否则取评分>=4或全部前20
    private var selectedAssetsForCut: [Asset] {
        if let sel = selectedAsset, let idx = appModel.assets.firstIndex(where: { $0.id == sel.id }) {
            return Array(appModel.assets[idx...idx])
        }
        return Array(appModel.assets.prefix(20))
    }

    private func updateColor(_ id: Int64, _ label: Int) {
        try? appModel.database.updateColorLabel(id: id, label: label)
        appModel.reloadAssets()
    }

    private func deleteAsset(_ id: Int64) {
        try? appModel.database.setDeleted(id: id, deleted: true)
        if selectedAsset?.id == id { selectedAsset = nil }
        appModel.reloadAssets()
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

