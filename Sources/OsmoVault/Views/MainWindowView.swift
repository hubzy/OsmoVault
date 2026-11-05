import SwiftUI
import AVFoundation
import AppKit

struct MainWindowView: View {
    @EnvironmentObject var appModel: AppModel
    @State private var showImporter = false
    @State private var selectedAssetID: Int64?
    @State private var section: SidebarItem? = .library
    @State private var playerController = PlayerController()
    /// 侧边栏右键来源后待确认移除的文件夹
    @State private var sourceToRemove: String?
    /// 手动补定位（单个 / 批量）
    @State private var locationTarget: LocationEditTarget?
    /// 批量动作落地后 +1，通知图库页退出多选（见 LibraryView.selectionResetToken）
    @State private var selectionResetToken = 0
    /// 这次补定位面板是不是从图库多选入口打开的。
    /// 只勾 1 条时面板走 .single（要回显已有坐标），不能靠 isBatch 判断该不该复位多选
    @State private var locateFromSelection = false
    /// 全屏播放：盖住整个窗口内容，同时把窗口推进原生全屏
    @State private var isTheater = false
    /// 标记「全屏是这次点进来的」，退出时才由我们负责还原窗口（用户自己按过绿灯就不动）
    @State private var theaterOwnsWindowFullScreen = false
    // 两列宽度在 ResizableSplit 内部用 @AppStorage 管理，这里不再持有

    private var removeMessage: String {
        guard let path = sourceToRemove else { return "" }
        let n = appModel.assets.filter { $0.filePath.hasPrefix(path) }.count
        return "将移除 \(path) 下的 \(n) 条索引记录，磁盘上的视频文件不会改动，但评分、颜色标签、收藏和手动补的定位会一并清除且无法恢复。"
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

    /// 回收站 / 一键出片是自成一体的一整页，右侧不再挂详情列；
    /// 重复素材页要点开卡片看详情，挂右侧详情列
    private var showsDetailPane: Bool { showsDetailPane(section) }

    private func showsDetailPane(_ item: SidebarItem?) -> Bool {
        switch item {
        case .trash, .quickCut, .videoEditor: return false
        default: return true
        }
    }

    private var sidebar: some View {
        SidebarView(selection: $section, assets: appModel.assets,
                    sources: appModel.sourceItems,
                    lastImportedAt: { appModel.lastImportedAt($0) },
                    onRemoveSource: { sourceToRemove = $0 },
                    duplicateCount: appModel.duplicateCount,
                    trashCount: appModel.trashCount,
                    albumCounts: appModel.albumCounts,
                    placeGroups: appModel.placeGroups)
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
        // 全屏播放盖住整窗（侧边栏 + 列表 + 详情）。
        // 工具栏的收放走 AppKit 的 `NSToolbar.isVisible`（见 setToolbarHidden），
        // **不要**改回 SwiftUI 的 toolbar 隐藏 API：那个会把 ToolbarItem 真的丢掉，恢复不回来
        .overlay {
            if isTheater, let asset = selectedAsset {
                TheaterView(asset: asset, controller: playerController, onExit: exitTheater)
                    .transition(.opacity)
            }
        }
        // 素材被删掉 / 取消选中时，全屏没有内容可播了，必须退出来
        .onChange(of: selectedAssetID) { _, newValue in
            if newValue == nil, isTheater { exitTheater() }
        }
        // 全屏动画走完再收工具栏：动画期间窗口会重建标题栏，提前改会被覆盖
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            if isTheater { setToolbarHidden(true) }
        }
        // 用户自己按绿灯 / ⌃⌘F 离开原生全屏时同步退出全屏播放，并把工具栏还回去
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            setToolbarHidden(false)
            if isTheater {
                theaterOwnsWindowFullScreen = false
                isTheater = false
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
            // 离开剪辑台时把预览播放也停掉（编辑器的 AVPlayer 独立于视图生命周期）
            if case .videoEditor = newValue {} else {
                appModel.videoEditor.editor?.pausePlayback()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appModel.applicationDidBecomeActive()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appModel.refreshNow()
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
                .disabled(appModel.isScanning)
                .help("重新扫描已导入的文件夹。往文件夹里新增照片会自动发现，这里用于手动补一次")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showImporter = true
                } label: {
                    Label("导入文件夹", systemImage: "plus.square.on.square")
                }
                .help("导入一个文件夹，自动扫描其中的照片 / 视频 / 实况照片")
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
                    // 补/改定位已写库：从多选发起的动作完成就取消多选，
                    // 别把选择模式留在页面上；详情页 / 右键单条编辑不动多选状态
                    if self.locateFromSelection { self.selectionResetToken += 1 }
                },
                onClear: {
                    appModel.clearLocation(ids: target.ids)
                    if self.locateFromSelection { self.selectionResetToken += 1 }
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
                if let msg = appModel.grabStatus {
                    VaultGlassContainer {
                        HStack(alignment: .top, spacing: Vault.S.small) {
                            Text(msg)
                                .font(.callout)
                                .lineLimit(3)
                                .frame(maxWidth: 360, alignment: .leading)
                            Spacer(minLength: 0)
                            // grabStatus 是 public @Published，View 层可直接置 nil，不必改 AppModel
                            VaultIconButton("关闭提示", systemImage: "xmark", hit: 24) {
                                appModel.grabStatus = nil
                            }
                        }
                    }
                }
                if let msg = appModel.autoRefreshStatus {
                    VaultGlassContainer {
                        HStack(alignment: .top, spacing: Vault.S.small) {
                            Label(msg, systemImage: "arrow.triangle.2.circlepath")
                                .font(.callout)
                                .lineLimit(3)
                                .frame(maxWidth: 360, alignment: .leading)
                            Spacer(minLength: 0)
                            VaultIconButton("关闭提示", systemImage: "xmark", hit: 24) {
                                appModel.autoRefreshStatus = nil
                            }
                        }
                    }
                    .transition(.opacity)
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
                        onEditLocation: {
                            locateFromSelection = false
                            locationTarget = .single(asset)
                        },
                        isTheater: isTheater,
                        onToggleTheater: enterTheater,
                        // LocationEditorSheet 打开时禁用裸字母 S，别抢走经纬度输入框的按键
                        shortcutsEnabled: locationTarget == nil
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
                    .accessibilityLabel(Text("关闭详情（地图回到整列）"))
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
            QuickCutPanel(onOpenEditor: { section = .videoEditor })
        case .videoEditor:
            // 剪辑台是自成一体的一整页（深色，FrameCut 编辑器全家桶）
            VideoEditorPage()
        case .duplicates:
            DuplicateView(onOpen: { selectedAssetID = $0 })
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
        case .place(let key):
            // tag 里存的已是归一化市名（「广东省·广州」和「广州市」都归为「广州」），
            // 筛选按市名匹配，两种格式的地名点一次全出来
            library(appModel.assets.filter { AppModel.city(of: $0.placeName) == key }, title: key)
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
                         hint: String? = nil) -> some View {
        LibraryView(title: title, assets: assets, version: appModel.assetsVersion,
                    selectedAssetID: $selectedAssetID,
                    onRate: { appModel.setRating(id: $0, rating: $1) },
                    onDelete: deleteAsset,
                    onToggleFavorite: { appModel.toggleFavorite(id: $0) },
                    onVisible: { appModel.noteVisible($0) },
                    // 批量补定位：每个页面都能多选后统一补/改定位。
                    // 单条走 .single：LocationEditorSheet 能回显已有坐标/地名；
                    // 多条才是 .batch（批量没有"已有坐标"的概念）
                    onAssignLocation: { list in
                        locateFromSelection = true
                        locationTarget = list.count == 1 ? .single(list[0]) : .batch(list)
                    },
                    // 右键补定位：**所有页面**都可用——有定位选「修改定位」，没有选「补定位」
                    onLocateItem: { id in
                        guard let a = appModel.asset(id: id) else { return }
                        locateFromSelection = false
                        locationTarget = .single(a)
                    },
                    // 所有页面都能多选后批量移入回收站；动作落地后同样退出多选
                    onDeleteSelected: {
                        appModel.moveToTrash(ids: $0.compactMap(\.id))
                        self.selectionResetToken += 1
                    },
                    emptyHint: hint,
                    selectionResetToken: selectionResetToken,
                    // 多选右键的批量评分 / 批量收藏：整批一次写库，不逐条刷
                    onRateSelected: { list, rating in
                        appModel.setRating(ids: list.compactMap(\.id), rating: rating)
                    },
                    onSetFavoriteSelected: { list, favorite in
                        appModel.setFavorite(ids: list.compactMap(\.id), favorite: favorite)
                    })
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
                    onEditLocation: { locationTarget = .single(asset) },
                    isTheater: isTheater,
                    onToggleTheater: enterTheater,
                    // LocationEditorSheet 打开时禁用裸字母 S，别抢走经纬度输入框的按键
                    shortcutsEnabled: locationTarget == nil
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

    // MARK: - 全屏播放

    private func enterTheater() {
        guard selectedAsset != nil, !isTheater else { return }
        isTheater = true
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        if window.styleMask.contains(.fullScreen) {
            // 本来就在全屏里：不会再有 didEnterFullScreen 通知，直接把工具栏收掉
            setToolbarHidden(true)
        } else {
            theaterOwnsWindowFullScreen = true
            window.toggleFullScreen(nil)   // 动画结束后由 didEnterFullScreen 收工具栏
        }
    }

    private func exitTheater() {
        guard isTheater else { return }
        // 只有"是我们推进去的"才由我们还原；用户本来就在全屏里就别乱动
        let restore = theaterOwnsWindowFullScreen
        theaterOwnsWindowFullScreen = false
        isTheater = false
        setToolbarHidden(false)
        if restore, let window = NSApp.keyWindow ?? NSApp.mainWindow,
           window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    /// 全屏播放期间收起窗口工具栏，退出时展开。
    ///
    /// 必须用 AppKit 的 `NSToolbar.isVisible`：SwiftUI 的 toolbar 隐藏 API 会把
    /// `ToolbarItem` 真正从工具栏里丢掉，切回 `.automatic` 也回不来（表现为顶部栏变矮、
    /// 导入/刷新按钮消失）。`isVisible` 只是整体收放，条目一个都不会少。
    private func setToolbarHidden(_ hidden: Bool) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        window.toolbar?.isVisible = !hidden
    }

    private func deleteAsset(_ id: Int64) {
        if selectedAssetID == id { selectedAssetID = nil }
        // 可恢复操作：保持中性（无 destructive role、无确认），但必须给一条反馈，
        // 否则素材点了直接消失，用户不知道去哪了。复用 AppModel 既有的底部 Toast 通道。
        appModel.moveToTrash(id: id)
        appModel.reportGrab("已移入回收站 · 可在回收站恢复")
    }

    private func grabFrame() {
        guard let asset = selectedAsset else { return }
        // 照片本身就是图，实况照片取其动态部分的当前帧
        guard let sourcePath = asset.playbackPath else {
            appModel.reportGrab("照片无需截取")
            return
        }
        var target = asset
        target.filePath = sourcePath
        let seconds = playerController.currentTime
        appModel.reportGrab("正在截取实况图…")
        // 取帧 + 导短视频可能要一两秒，放到后台跑，别卡住界面
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let (photoURL, videoURL) = try FrameGrabService.grabLivePhoto(asset: target, at: seconds)
                // 入库（注册成实况照片）是异步的，丢到 Task 里跑
                Task { await appModel.importLivePhoto(photoPath: photoURL.path, videoPath: videoURL.path) }
                DispatchQueue.main.async {
                    appModel.reportGrab("已截取实况图：\(photoURL.lastPathComponent)（含动态，可在「实况照片」找到）")
                }
            } catch {
                DispatchQueue.main.async {
                    appModel.reportGrab("截取失败：\(error.localizedDescription)")
                }
            }
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
            VaultGlassContainer {
                Label("正在发现文件…", systemImage: "magnifyingglass")
            }
        case .importing(let indexed, let total):
            VaultGlassContainer {
                HStack {
                    if let total {
                        ProgressView(value: Double(indexed) / Double(max(total, 1)))
                    } else {
                        ProgressView()
                    }
                    Text(progress.currentFile ?? "").lineLimit(1).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 420)
        case .finished(let newAssets, let duplicates, _):
            VaultGlassContainer {
                HStack(spacing: 10) {
                    Image(systemName: newAssets > 0 ? "checkmark.circle.fill" : "checkmark.circle")
                        .foregroundStyle(newAssets > 0 ? .green : .secondary)
                    Text(summary(newAssets: newAssets, duplicates: duplicates))
                    if newAssets > 0 {
                        Divider().frame(height: 14)
                        Button("只看该文件夹") { onShowFolder() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    VaultIconButton("关闭", systemImage: "xmark", symbolSize: 12, hit: 24) {
                        onDismiss()
                    }
                }
            }
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
/// （一键出片页也复用这个组件分「素材池 | 预览」两列，所以是 internal）
///
/// 之前"不好拖、不丝滑"的三个原因，这里逐个处理：
/// 1. **必须用 `.global` 坐标空间**。`DragGesture` 默认是 `.local`，也就是以被拖视图自身
///    为原点；而拖动时这一列本身在移动，位移会被视图的移动"吃掉"，表现就是分隔条追不上
///    鼠标、走走停停。
/// 2. **拖动中的宽度只放本地 `@State`，松手才写 UserDefaults**。每帧写 `@AppStorage`
///    会让上层 `body` 整棵树重算（时间轴里是几千张卡），一帧一帧掉下去就是卡顿。
/// 3. **用增量 + 夹取**（而不是"起点 + 总位移"）：拖到最小/最大宽度卡住后反向立刻跟手，
///    不存在要先把越界的位移"退回来"的死区。
struct ResizableSplit<Leading: View, Trailing: View>: View {
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
        // 整个分割条（高亮 + 拖拽 + 光标）都用原生 NSView 绘制，SwiftUI 不再参与
        // 这一区域的重绘。这样 AppKit 的 addCursorRect 才不会被 SwiftUI 的光标管理
        // 在重绘时重置掉——之前无论用 NSCursor.push 还是 addCursorRect 都失败，根因
        // 就在这附近还有 SwiftUI 重绘。高亮改由 NSView 内部的 CALayer 画。
        SplitHandleView(
            isLeading: side == .leading,
            range: range,
            minOther: minOther,
            maxFraction: maxFraction,
            handleWidth: handleWidth,
            total: total,
            current: current,
            defaultValue: defaultValue,
            live: $live,
            stored: $stored
        )
        .frame(width: handleWidth)
        .frame(maxHeight: .infinity)
        .help("拖动调整宽度，双击恢复默认")
    }
}

/// 原生 NSView 绘制的分割条：高亮、拖拽、光标全在这里面，SwiftUI 完全不参与。
///
/// 之前两版都失败的根因：只要这一带还有 SwiftUI 重绘（无论是被 @State 驱动的
/// 胶囊高亮，还是被 .onHover 触发的重绘），AppKit 在重绘时就会把光标重置回箭头，
/// 于是「高亮有了、光标没变」。现在高亮改由本视图内部的 CALayer 绘制，SwiftUI 不
/// 再重绘此区域，addCursorRect 才能稳定生效。
fileprivate struct SplitHandleView: NSViewRepresentable {
    var isLeading: Bool
    var range: ClosedRange<Double>
    var minOther: CGFloat
    var maxFraction: Double?
    var handleWidth: CGFloat
    var total: CGFloat
    var current: CGFloat
    var defaultValue: Double
    @Binding var live: Double?
    @Binding var stored: Double

    func makeNSView(context: Context) -> NSView {
        let view = _HandleView()
        view.configure(isLeading: isLeading, range: range, minOther: minOther,
                       maxFraction: maxFraction, handleWidth: handleWidth,
                       defaultValue: defaultValue,
                       live: $live, stored: $stored)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? _HandleView {
            view.update(total: total, current: current)
            // 布局/尺寸变化时让窗口重算光标区域，保证与命中区一致
            nsView.window?.invalidateCursorRects(for: nsView)
        }
    }

    final class _HandleView: NSView {
        private let highlight = CALayer()
        private var isHovering = false
        private var isDragging = false
        private var isLeading = true
        private var range = 0.0...1000.0
        private var minOther: CGFloat = 300
        private var maxFraction: Double?
        private var handleWidth: CGFloat = 14
        private var defaultValue = 0.0
        private var total: CGFloat = 0
        private var current: CGFloat = 0
        private var startWidth: Double = 0
        private var startLocation: CGFloat = 0
        private var live: Binding<Double?>?
        private var stored: Binding<Double>?
        private var pan: NSPanGestureRecognizer!

        func configure(isLeading: Bool, range: ClosedRange<Double>, minOther: CGFloat,
                       maxFraction: Double?, handleWidth: CGFloat, defaultValue: Double,
                       live: Binding<Double?>, stored: Binding<Double>) {
            self.isLeading = isLeading
            self.range = range
            self.minOther = minOther
            self.maxFraction = maxFraction
            self.handleWidth = handleWidth
            self.defaultValue = defaultValue
            self.live = live
            self.stored = stored
        }

        func update(total: CGFloat, current: CGFloat) {
            self.total = total
            self.current = current
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            highlight.cornerRadius = 1.5
            layer?.addSublayer(highlight)
            pan = NSPanGestureRecognizer(target: self, action: #selector(panChanged(_:)))
            addGestureRecognizer(pan)
            let dbl = NSClickGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
            dbl.numberOfClicksRequired = 2
            addGestureRecognizer(dbl)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            let active = isDragging || isHovering
            let w: CGFloat = active ? 3 : 1
            highlight.frame = CGRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height)
            let alpha: CGFloat = isDragging ? 0.42 : (isHovering ? 0.28 : 0.12)
            highlight.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        }

        // 自己接收事件：拖拽手势和光标都在这一层，不再需要穿透
        override func hitTest(_ point: NSPoint) -> NSView? { self }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
            addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) {
            isHovering = true
            needsLayout = true
        }
        override func mouseExited(with event: NSEvent) {
            isHovering = false
            needsLayout = true
        }

        private func maxControlled(total: CGFloat) -> Double {
            let room = Double(max(0, total - handleWidth - minOther))
            var cap = min(range.upperBound, max(range.lowerBound, room))
            if let mf = maxFraction { cap = min(cap, Double(total) * mf) }
            return max(range.lowerBound, cap)
        }

        @objc private func panChanged(_ gesture: NSPanGestureRecognizer) {
            switch gesture.state {
            case .began:
                isDragging = true
                startWidth = live?.wrappedValue ?? Double(current)
                startLocation = gesture.location(in: nil).x
                needsLayout = true
            case .changed:
                let t = gesture.location(in: nil).x - startLocation
                let dir: Double = isLeading ? 1 : -1
                let next = startWidth + dir * Double(t)
                live?.wrappedValue = min(max(next, range.lowerBound), maxControlled(total: total))
            case .ended, .cancelled, .failed:
                isDragging = false
                if let value = live?.wrappedValue { stored?.wrappedValue = value }
                live?.wrappedValue = nil
                needsLayout = true
            default:
                break
            }
        }

        @objc private func doubleTap(_ gesture: NSClickGestureRecognizer) {
            guard gesture.state == .ended else { return }
            live?.wrappedValue = nil
            stored?.wrappedValue = defaultValue
        }
    }
}
