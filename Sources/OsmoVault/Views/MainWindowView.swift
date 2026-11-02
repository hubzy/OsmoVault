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
    /// 手动补定位（单个 / 批量）
    @State private var locationTarget: LocationEditTarget?
    /// 地图页右侧详情列宽度，拖动后记住，下次打开不用重新拖
    @AppStorage("mapDetailWidth") private var mapDetailWidth: Double = 380
    /// 图库页缩略图列宽度。拖过一次就记下来，窗口宽度怎么变都以这个为准
    @AppStorage("libraryColumnWidth") private var libraryColumnWidth: Double = 620

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

    /// 回收站 / 一键出片 / 重复素材是自成一体的一整页，右侧不再挂详情列
    private var showsDetailPane: Bool {
        switch section {
        case .trash, .quickCut, .duplicates: return false
        default: return true
        }
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
                } detail: {
                    libraryAndDetail
                        .navigationSplitViewColumnWidth(min: 680, ideal: 1080, max: 4000)
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
        .sheet(item: $locationTarget) { target in
            LocationEditorSheet(
                target: target,
                onApply: { coordinate, placeName in
                    appModel.setLocation(ids: target.ids,
                                         latitude: coordinate.latitude,
                                         longitude: coordinate.longitude,
                                         placeName: placeName)
                },
                onClear: {
                    appModel.clearLocation(ids: target.ids)
                }
            )
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

    /// 地图占左侧，详情是右侧一**列**（和图库一样，不是浮窗），
    /// 中间的分割条可以拖，宽度记在 UserDefaults 里。没选中素材时地图占满整列
    private var mapContent: some View {
        HStack(spacing: 0) {
            MapView(assets: appModel.geotaggedAssets,
                    version: appModel.assetsVersion,
                    selectedAssetID: $selectedAssetID)
                .frame(minWidth: 320)

            if selectedAsset != nil {
                // 详情在右：向右拖 → 详情变窄，所以方向取 -1
                ResizeHandle(width: $mapDetailWidth, range: 300...760, direction: -1)
                mapDetailColumn
            }
        }
        .navigationSplitViewColumnWidth(min: 520, ideal: 900, max: 4000)
    }

    /// 缩略图列 + 详情列。
    ///
    /// 这里用自己画的分割条，而不是 NavigationSplitView 的第三列：三列的宽度
    /// 只能给 min/ideal/max，拿不到拖动后的实际值也没法绑定，拖完下次启动又回去了。
    /// 自己画之后宽度直接写进 @AppStorage，拖一次永久生效
    private var libraryAndDetail: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if showsDetailPane {
                    mainContent.frame(width: contentWidth(in: geo.size.width))
                    ResizeHandle(width: $libraryColumnWidth, range: 360...1100, direction: 1)
                    detailContent.frame(minWidth: 300, maxWidth: .infinity)
                } else {
                    mainContent.frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// 记住的宽度优先，但窗口太窄时让详情列保住 300 的下限，避免两列挤出可视区
    private func contentWidth(in total: CGFloat) -> CGFloat {
        let room = max(360, total - 9 - 300)
        return min(CGFloat(libraryColumnWidth), room)
    }

    @ViewBuilder
    private var mapDetailColumn: some View {
        if let asset = selectedAsset {
            VStack(spacing: 0) {
                LibraryPathBar(path: libraryPath, assetCount: libraryPathCount)
                Divider()
                ZStack(alignment: .topTrailing) {
                    AssetDetailView(
                        asset: asset,
                        controller: playerController,
                        onRate: { appModel.setRating(id: $0, rating: $1) },
                        onColor: { appModel.setColorLabel(id: $0, label: $1) },
                        onToggleFavorite: { appModel.toggleFavorite(id: asset.id ?? 0) },
                        onGrab: grabFrame,
                        onDelete: { deleteAsset(asset.id ?? 0) },
                        onEditLocation: { locationTarget = .single(asset) }
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
                    .help("关闭详情（地图回到整列）")
                    .padding(8)
                }
            }
            .frame(width: mapDetailWidth)
            .background(.background)
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
                        hint: "「\(album.name)」里还没有素材",
                        isLocationPage: id == "noGPS")
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
    private func library(_ assets: [Asset], title: String = "图库",
                         hint: String? = nil, isLocationPage: Bool = false) -> some View {
        LibraryView(title: title, assets: assets, version: appModel.assetsVersion,
                    selectedAssetID: $selectedAssetID,
                    onRate: { appModel.setRating(id: $0, rating: $1) },
                    onDelete: deleteAsset,
                    onToggleFavorite: { appModel.toggleFavorite(id: $0) },
                    onVisible: { appModel.noteVisible($0) },
                    isLocationPage: isLocationPage,
                    // 只在「补定位」页挂这个入口，其他页面不再冒出「补定位 N」按钮
                    onAssignLocation: isLocationPage ? { locationTarget = .batch($0) } : nil,
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
                    onDelete: { deleteAsset(asset.id ?? 0) },
                    onEditLocation: { locationTarget = .single(asset) }
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
        // 视频选中即播；实况照片只预载，等鼠标悬停画面才播（且默认静音）
        playerController.load(url: URL(fileURLWithPath: path),
                              autoplay: asset.kind != .livePhoto,
                              livePhoto: asset.kind == .livePhoto)
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

/// 可拖动的分割条。宽度直接写回绑定的 @AppStorage（拖完即落盘），
/// 下次启动自动恢复，不用每次重拖
private struct ResizeHandle: View {
    @Binding var width: Double
    var range: ClosedRange<Double>
    /// +1：向右拖 = 被控列变宽（列在分割条左边）；-1：列在右边，方向相反
    var direction: Double = 1

    @State private var dragging = false
    @State private var startWidth: Double = 0
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.primary.opacity(hovering || dragging ? 0.22 : 0.10))
                .frame(width: 1)
        }
        .frame(width: 9)
        .contentShape(Rectangle())
        .onHover { over in
            hovering = over
            if over {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if !dragging {
                        dragging = true
                        startWidth = width
                    }
                    width = min(max(startWidth + direction * value.translation.width,
                                    range.lowerBound), range.upperBound)
                }
                .onEnded { _ in dragging = false }
        )
    }
}
