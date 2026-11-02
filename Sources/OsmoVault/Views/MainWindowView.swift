import SwiftUI
import AVFoundation

struct MainWindowView: View {
    @EnvironmentObject var appModel: AppModel
    @State private var showImporter = false
    @State private var selectedAssetID: Int64?
    @State private var section: SidebarItem? = .library
    @State private var grabStatus: String?
    @State private var playerController = PlayerController()
    /// 侧边栏右键来源后待确认移除的文件夹
    @State private var sourceToRemove: String?

    private var removeMessage: String {
        guard let path = sourceToRemove else { return "" }
        let n = appModel.assets.filter { $0.filePath.hasPrefix(path) }.count
        return "将移除 \(path) 下的 \(n) 条索引记录，磁盘上的视频文件不会改动。"
    }

    /// 统一按 id 取最新素材：库重载后详情不会停留在旧副本上。
    /// 走 AppModel 的 id 索引而不是线性查找——8000 条时每帧一次 O(n) 很可观
    private var selectedAsset: Asset? {
        guard let id = selectedAssetID else { return nil }
        return appModel.asset(id: id)
    }

    /// 顶部路径条跟随当前素材：选中素材时显示它所在目录，否则显示最近导入的文件夹
    private var libraryPath: String? {
        if let asset = selectedAsset {
            return (asset.filePath as NSString).deletingLastPathComponent
        }
        return appModel.libraryRoots.first
    }

    private var libraryPathCount: Int {
        guard let path = libraryPath else { return appModel.assets.count }
        let n = appModel.assets.filter { $0.filePath.hasPrefix(path) }.count
        return n > 0 ? n : appModel.assets.count
    }

    /// 地图页要走两列布局：地图本身占满侧边栏之外的全部空间，
    /// 详情不再常驻右侧，点标记才浮出来。三列布局做不到「全屏」
    private var isMapMode: Bool {
        if case .map = section { return true }
        return false
    }

    private var sidebar: some View {
        SidebarView(selection: $section, assets: appModel.assets,
                    sources: appModel.sourceItems,
                    lastImportedAt: { appModel.lastImportedAt($0) },
                    onRemoveSource: { sourceToRemove = $0 },
                    duplicateCount: appModel.duplicateCount,
                    albumCounts: appModel.albumCounts,
                    placeCounts: appModel.places)
    }

    var body: some View {
        Group {
            if isMapMode {
                NavigationSplitView {
                    sidebar
                } detail: {
                    mapContent
                }
            } else {
                NavigationSplitView {
                    sidebar
                } content: {
                    mainContent
                        .navigationSplitViewColumnWidth(min: 380, ideal: 560, max: 1200)
                } detail: {
                    detailContent
                        .navigationSplitViewColumnWidth(min: 320, ideal: 460)
                }
            }
        }
        // 切到地图页先清空选中：否则详情浮层会残留上一页看的那一条
        .onChange(of: section) { _, newValue in
            if case .map = newValue {
                selectedAssetID = nil
                playerController.unload()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showImporter = true
                } label: {
                    Label("导入文件夹", systemImage: "plus.square.on.square")
                }
            }
            // 截帧入口统一收到右侧「功能区」，这里不再重复放一个按钮
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let folder = urls.first {
                appModel.scanFolder(folder)
            }
        }
        .alert("从库中移除", isPresented: Binding(
            get: { sourceToRemove != nil },
            set: { if !$0 { sourceToRemove = nil } }
        )) {
            Button("移除", role: .destructive) {
                if let path = sourceToRemove {
                    appModel.removeSource(path)
                    if case .source(let p) = section, p == path { section = .library }
                }
                sourceToRemove = nil
            }
            Button("取消", role: .cancel) { sourceToRemove = nil }
        } message: {
            Text(removeMessage)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 6) {
                // 注意用 scanProgress 而不是 isScanning 判断：完成后 isScanning 已经置 false，
                // 用它会让"完成：新增 N"这条结果一闪而过，等于没有提示
                if let p = appModel.scanProgress {
                    ScanStatusBar(progress: p,
                                  folderName: appModel.lastImport.map {
                                      URL(fileURLWithPath: $0.path).lastPathComponent
                                  },
                                  onShowFolder: {
                                      if let path = appModel.lastImport?.path { section = .source(path) }
                                  },
                                  onDismiss: { appModel.dismissScanStatus() })
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

    // MARK: - 地图页

    /// 全屏地图 + 右侧浮出的详情卡（点标记才出现）
    private var mapContent: some View {
        MapView(assets: appModel.geotaggedAssets,
                version: appModel.assetsVersion,
                selectedAssetID: $selectedAssetID)
            .overlay(alignment: .trailing) { mapDetailCard }
            .animation(.easeOut(duration: 0.18), value: selectedAssetID)
            .navigationSplitViewColumnWidth(min: 520, ideal: 900, max: 4000)
    }

    @ViewBuilder
    private var mapDetailCard: some View {
        if let asset = selectedAsset {
            HStack(spacing: 0) {
                Divider()
                ZStack(alignment: .topTrailing) {
                    AssetDetailView(
                        asset: asset,
                        controller: playerController,
                        onRate: { appModel.setRating(id: $0, rating: $1) },
                        onColor: { appModel.setColorLabel(id: $0, label: $1) },
                        onToggleFavorite: { appModel.toggleFavorite(id: asset.id ?? 0) },
                        onGrab: grabFrame,
                        onDelete: { deleteAsset(asset.id ?? 0) }
                    )
                    .onAppear { load(asset) }
                    .onChange(of: asset.id) { _, _ in
                        if let a = selectedAsset { load(a) }
                    }
                    Button {
                        selectedAssetID = nil
                        playerController.unload()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.borderless)
                    .help("关闭详情")
                    .padding(8)
                }
                .frame(width: 380)
                .background(.regularMaterial)
                .shadow(radius: 8)
            }
            .frame(maxHeight: .infinity)
            .transition(.move(edge: .trailing))
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
        case .duplicates:
            DuplicateView()
        case .map:
            EmptyView()   // 地图页走两列布局，不会走到这里
        case .smartAlbum(let id):
            if let album = SmartAlbum.find(id: id) {
                library(album.filter(appModel.assets),
                        title: album.name,
                        hint: "「\(album.name)」里还没有素材")
            } else {
                placeholder("相册不存在")
            }
        case .place(let name):
            library(appModel.assets.filter { $0.placeName == name }, title: name)
        case .source(let path):
            let name = URL(fileURLWithPath: path).lastPathComponent
            library(appModel.assets.filter { $0.filePath.hasPrefix(path) },
                    title: name, hint: "「\(name)」下没有素材")
        default:
            library(appModel.assets)
        }
    }

    /// 图库页：网格与时间轴合并在一起，顶部统一显示总数
    private func library(_ assets: [Asset], title: String = "图库", hint: String? = nil) -> some View {
        LibraryView(title: title, assets: assets, version: appModel.assetsVersion,
                    selectedAssetID: $selectedAssetID,
                    onRate: { appModel.setRating(id: $0, rating: $1) },
                    onDelete: deleteAsset,
                    onToggleFavorite: { appModel.toggleFavorite(id: $0) },
                    onVisible: { appModel.noteVisible($0) },
                    emptyHint: hint)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }

    // MARK: - 详情区

    @ViewBuilder
    private var detailContent: some View {
        VStack(spacing: 0) {
            // 库位置条常驻：一眼能看到当前导入的是哪个文件夹
            LibraryPathBar(path: libraryPath, assetCount: libraryPathCount)
            Divider()

            if let asset = selectedAsset {
                AssetDetailView(
                    asset: asset,
                    controller: playerController,
                    onRate: { appModel.setRating(id: $0, rating: $1) },
                    onColor: { appModel.setColorLabel(id: $0, label: $1) },
                    onToggleFavorite: { appModel.toggleFavorite(id: asset.id ?? 0) },
                    onGrab: grabFrame,
                    onDelete: { deleteAsset(asset.id ?? 0) }
                )
                .onAppear { load(asset) }
                .onChange(of: asset.id) { _, _ in
                    if let a = selectedAsset { load(a) }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
                    Text("选择素材查看详情").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func load(_ asset: Asset) {
        // 照片没得播；实况照片加载它的动态部分
        guard let path = asset.playbackPath else {
            playerController.unload()
            return
        }
        playerController.load(url: URL(fileURLWithPath: path))
    }

    // MARK: - 操作

    private func deleteAsset(_ id: Int64) {
        if selectedAssetID == id { selectedAssetID = nil }
        appModel.moveToTrash(id: id)
    }

    private func grabFrame() {
        guard let asset = selectedAsset else { return }
        // 照片本身就是图，实况照片取其动态部分的当前帧
        guard let sourcePath = asset.playbackPath else {
            grabStatus = "照片无需截取"
            return
        }
        var target = asset
        target.filePath = sourcePath
        let seconds = playerController.currentTime
        do {
            let url = try FrameGrabService.grab(asset: target, at: seconds)
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
    /// 导入的文件夹名，结果里带上，多个来源时才知道这次是哪一份
    var folderName: String?
    /// 跳到刚导入的那个文件夹（侧边栏「导入来源」里能对应上）
    var onShowFolder: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        switch progress.state {
        case .discovering:
            Label("正在发现文件…", systemImage: "magnifyingglass")
                .padding(8).background(.bar, in: RoundedRectangle(cornerRadius: 8))
        case .importing(let indexed, let total):
            HStack {
                if let total {
                    ProgressView(value: Double(indexed) / Double(max(total, 1)))
                } else {
                    ProgressView()
                }
                Text(progress.currentFile ?? "").lineLimit(1).font(.caption).foregroundStyle(.secondary)
            }
            .padding(8).frame(maxWidth: 420).background(.bar, in: RoundedRectangle(cornerRadius: 8))
        case .finished(let newAssets, let duplicates, _):
            HStack(spacing: 10) {
                Image(systemName: newAssets > 0 ? "checkmark.circle.fill" : "checkmark.circle")
                    .foregroundStyle(newAssets > 0 ? .green : .secondary)
                Text(summary(newAssets: newAssets, duplicates: duplicates))
                if newAssets > 0 {
                    Divider().frame(height: 14)
                    Button("只看该文件夹") { onShowFolder() }
                        .buttonStyle(.borderless)
                }
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("关闭")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.bar, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func summary(newAssets: Int, duplicates: Int) -> String {
        let prefix = folderName.map { "「\($0)」" } ?? "导入完成"
        if newAssets > 0 {
            return "\(prefix) 导入完成：新增 \(newAssets) 个，跳过重复 \(duplicates) 个"
        }
        return "\(prefix) 导入完成：没有新素材，\(duplicates) 个已存在"
    }
}
