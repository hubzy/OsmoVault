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
    // 两列宽度在 ResizableSplit 内部用 @AppStorage 管理，这里不再持有

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
    private var showsDetailPane: Bool { showsDetailPane(section) }

    private func showsDetailPane(_ item: SidebarItem?) -> Bool {
        switch item {
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
        // 换页面时先把声音收掉：详情面板可能已经整体不在了（地图 / 回收站 / 一键出片 / 重复素材）。
        // AVPlayer 独立于视图，光靠视图消失并不会停；这里再兜一道，切页必定静音
        .onChange(of: section) { _, newValue in
            if case .map = newValue {
                // 地图走另一套布局，详情整块消失：清空选中，回来不残留旧详情
                selectedAssetID = nil
                playerController.unload()
            } else {
                // 其余页面（含同列换集合）一律停播，避免"人已经走了声音还在"
                playerController.pause()
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
    ///
    /// `trailingVisible` 只控制"有没有详情列"，不改变 MapView 的位置：
    /// 否则选中/取消选中时 MapView 会被重建，地图镜头跟着回弹
    private var mapContent: some View {
        // 详情列最宽可拖到分割区域的一半；range 上限给大些，实际由 maxFraction 收口
        ResizableSplit(key: "mapDetailWidth", defaultValue: 380,
                       range: 300...4000, side: .trailing, minOther: 320,
                       maxFraction: 0.5,
                       trailingVisible: selectedAsset != nil,
                       leading: {
                           MapView(assets: appModel.geotaggedAssets,
                                   version: appModel.assetsVersion,
                                   selectedAssetID: $selectedAssetID)
                       },
                       trailing: { mapDetailColumn })
            .navigationSplitViewColumnWidth(min: 520, ideal: 900, max: 4000)
    }

    /// 缩略图列 + 详情列。
    ///
    /// 这里用自己画的分割条，而不是 NavigationSplitView 的第三列：三列的宽度
    /// 只能给 min/ideal/max，拿不到拖动后的实际值也没法绑定，拖完下次启动又回去了。
    private var libraryAndDetail: some View {
        ResizableSplit(key: "libraryColumnWidth", defaultValue: 620,
                       range: 360...1100, side: .leading, minOther: 300,
                       trailingVisible: showsDetailPane,
                       leading: { mainContent },
                       trailing: { detailContent })
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
                    // 所有页面都能多选后批量移入回收站
                    onDeleteSelected: { appModel.moveToTrash(ids: $0.compactMap(\.id)) },
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

/// 左右两栏 + 可拖动分割条。宽度记在 UserDefaults 里，下次启动自动恢复。
///
/// 之前"不好拖、不丝滑"的三个原因，这里逐个处理：
/// 1. **必须用 `.global` 坐标空间**。`DragGesture` 默认是 `.local`，也就是以被拖视图自身
///    为原点；而拖动时这一列本身在移动，位移会被视图的移动"吃掉"，表现就是分隔条追不上
///    鼠标、走走停停。
/// 2. **拖动中的宽度只放本地 `@State`，松手才写 UserDefaults**。每帧写 `@AppStorage`
///    会让上层 `body` 整棵树重算（时间轴里是几千张卡），一帧一帧掉下去就是卡顿。
/// 3. **用增量 + 夹取**（而不是"起点 + 总位移"）：拖到最小/最大宽度卡住后反向立刻跟手，
///    不存在要先把越界的位移"退回来"的死区。
private struct ResizableSplit<Leading: View, Trailing: View>: View {
    enum Side {
        /// 受控列在左（图库：缩略图列宽度可变）
        case leading
        /// 受控列在右（地图：右侧详情列宽度可变）
        case trailing
    }

    let key: String
    let defaultValue: Double
    var range: ClosedRange<Double>
    var side: Side
    /// 非受控那一列的最小宽度
    var minOther: CGFloat = 300
    /// 受控列最大占比（相对分割区域总宽）。nil = 不限占比，只用 range
    var maxFraction: Double?
    /// 右边那列是否显示。为 false 时左边独占整列
    var trailingVisible: Bool = true
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    @AppStorage private var stored: Double
    /// 拖动过程中的临时宽度，松手后清空
    @State private var live: Double?
    @State private var lastTranslation: CGFloat = 0
    @State private var dragging = false
    @State private var hovering = false

    /// 命中区 14pt：1pt 的细线用鼠标根本点不准，得留出足够的抓取范围
    private let handleWidth: CGFloat = 14

    init(key: String, defaultValue: Double, range: ClosedRange<Double>,
         side: Side, minOther: CGFloat = 300, maxFraction: Double? = nil,
         trailingVisible: Bool = true,
         @ViewBuilder leading: @escaping () -> Leading,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.key = key
        self.defaultValue = defaultValue
        self.range = range
        self.side = side
        self.minOther = minOther
        self.maxFraction = maxFraction
        self.trailingVisible = trailingVisible
        self.leading = leading
        self.trailing = trailing
        _stored = AppStorage(wrappedValue: defaultValue, key)
    }

    var body: some View {
        GeometryReader { geo in
            let width = controlledWidth(total: geo.size.width)
            HStack(spacing: 0) {
                if !trailingVisible {
                    leading().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if side == .leading {
                    leading().frame(width: width)
                    handle(total: geo.size.width, current: width)
                    trailing().frame(minWidth: minOther, maxWidth: .infinity)
                } else {
                    leading().frame(minWidth: minOther, maxWidth: .infinity)
                    handle(total: geo.size.width, current: width)
                    trailing().frame(width: width)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - 宽度

    /// 受控列能到的最大值：给另一列留出 minOther，再叠加最大占比（如果设了）
    private func maxControlled(total: CGFloat) -> Double {
        let room = Double(max(0, total - handleWidth - minOther))
        var cap = min(range.upperBound, max(range.lowerBound, room))
        if let maxFraction {
            cap = min(cap, Double(total) * maxFraction)
        }
        return max(range.lowerBound, cap)
    }

    private func controlledWidth(total: CGFloat) -> CGFloat {
        let desired = live ?? stored
        return CGFloat(min(max(desired, range.lowerBound), maxControlled(total: total)))
    }

    // MARK: - 分割条

    private func handle(total: CGFloat, current: CGFloat) -> some View {
        ZStack {
            // 平时 1pt 细线，hover / 拖动时变成 3pt 的药丸，明确告诉用户这里能拖
            Capsule()
                .fill(Color.primary.opacity(dragging ? 0.42 : (hovering ? 0.28 : 0.12)))
                .frame(width: dragging || hovering ? 3 : 1)
        }
        .frame(width: handleWidth)
        .frame(maxHeight: .infinity)
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
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if !dragging {
                        dragging = true
                        lastTranslation = 0
                    }
                    let delta = value.translation.width - lastTranslation
                    lastTranslation = value.translation.width
                    let dir: Double = side == .leading ? 1 : -1
                    let next = (live ?? Double(current)) + dir * Double(delta)
                    live = min(max(next, range.lowerBound), maxControlled(total: total))
                }
                .onEnded { _ in
                    dragging = false
                    lastTranslation = 0
                    // 只在松手时落盘一次，拖动过程中不碰 UserDefaults
                    if let live { stored = live }
                    live = nil
                }
        )
        // 双击回到默认宽度：拖歪了不用一点点拽回来
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                live = nil
                stored = defaultValue
            }
        )
        .help("拖动调整宽度，双击恢复默认")
    }
}
