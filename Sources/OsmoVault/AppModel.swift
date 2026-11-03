import SwiftUI

/// 侧边栏「拍摄地」的一行或一组。
/// province 非 nil = 有省层级，折叠展示（标题 = 省名，子行 = 城市）；nil = 直辖市/海外等地名，直接平铺
struct SidebarPlaceGroup: Identifiable {
    var id: String { province ?? "~" + (cities.first?.city ?? "") }
    let province: String?
    let total: Int
    let cities: [(city: String, count: Int)]
}

@MainActor
final class AppModel: ObservableObject {
    @Published var assets: [Asset] = []
    /// 回收站里的素材数（侧边栏「回收站」徽标）。
    /// assets 只含未删除素材，回收站数量需要单独统计，随 reloadAssets 一起刷新
    @Published private(set) var trashCount: Int = 0
    /// 素材集合的版本号。视图用它判断缓存的分组结果要不要重算，
    /// 不用去比较 8000 条 Asset（值类型，逐条 Equatable 太贵）
    @Published private(set) var assetsVersion: UInt64 = 0
    @Published var isScanning = false
    @Published var scanProgress: ScanProgress?
    /// 导入过的文件夹，最近导入的在前
    @Published private(set) var scanRoots: [String] = []
    /// 导入历史（持久化）：最近一次在前，重启后「最近导入」仍在
    @Published private(set) var importHistory: [ImportRecord] = []
    /// 「截取实况图」的结果提示，由 MainWindowView 显示
    @Published var grabStatus: String?
    /// 自动刷新（监听文件夹）的结果提示，几秒后自己消失
    @Published var autoRefreshStatus: String?

    let database: AppDatabase
    private var placeNameTask: Task<Void, Never>?
    /// 已导入文件夹的实时监听：有新照片/视频落盘就自动增量扫描
    private var watcher: FolderWatcher?
    private var autoRefreshStatusTask: Task<Void, Never>?
    private var lastAutoScanAt = Date.distantPast
    /// 手动补定位后的地名反查，与扫描期的地名任务分开，互不取消
    private var manualPlaceTask: Task<Void, Never>?
    private static let rootsKey = "OsmoVault.scanRoots"
    private static let historyKey = "OsmoVault.importHistory"
    private static let sidecarMigrationKey = "OsmoVault.sidecarMigration.v1"

    /// 最近一次导入记录（可能来自上一次启动）
    var lastImport: ImportRecord? { importHistory.first ?? fallbackImport }
    /// 最近一次导入新增的素材 id
    var lastImportIDs: [Int64] { lastImport?.ids ?? [] }

        init() {
        self.database = (try? AppDatabase.open()) ?? AppDatabase.inMemory()
        self.scanRoots = UserDefaults.standard.stringArray(forKey: Self.rootsKey) ?? []
        self.importHistory = Self.loadHistory()
        reloadAssets()
        // 启动就开始盯着已导入的文件夹：往里丢照片不用再手动导入一次
        startWatching()
        migrateManualAnnotationsIfNeeded()
        // 老版本会把每张实况照片的动态视频都抽出来落盘，几千张能攒到几十 GB，
        // 而且新代码会直接复用已有文件、不会主动缩。启动时按配额清一次。
        Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)   // 避开启动高峰
            MotionPhoto.trimCache()
        }
    }

    // MARK: - 导入历史持久化

    private static func loadHistory() -> [ImportRecord] {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let list = try? JSONDecoder().decode([ImportRecord].self, from: data) else { return [] }
        return list
    }

    private func saveHistory() {
        let trimmed = Array(importHistory.prefix(40))
        UserDefaults.standard.set(try? JSONEncoder().encode(trimmed), forKey: Self.historyKey)
    }

    /// 历史为空（比如用旧版本导入过）时，用入库时间最近的一批素材反推出"最近导入"。
    /// 判断批次：与最新 createdAt 相差 10 分钟内的算同一批。
    private func rebuildFallbackImport() {
        guard importHistory.isEmpty else { fallbackImport = nil; return }
        let dated = assets.compactMap { a -> (Int64, Date)? in
            guard let id = a.id else { return nil }
            return (id, a.createdAt)
        }
        guard let newest = dated.map(\.1).max() else { fallbackImport = nil; return }
        let ids = dated.filter { newest.timeIntervalSince($0.1) < 600 }.map(\.0)
        guard !ids.isEmpty else { fallbackImport = nil; return }
        let idSet = Set(ids)
        let dirs = assets.filter { idSet.contains($0.id ?? -1) }
            .map { ($0.filePath as NSString).deletingLastPathComponent }
        let dir = Dictionary(grouping: dirs, by: { $0 })
            .mapValues(\.count)
            .max(by: { $0.value < $1.value })?.key ?? ""
        fallbackImport = ImportRecord(path: dir, at: newest,
                                      added: ids.count, duplicates: 0, ids: ids)
    }

    // MARK: - 来源文件夹

    private func addScanRoot(_ path: String) {
        var roots = scanRoots.filter { $0 != path }
        roots.insert(path, at: 0)
        scanRoots = roots
        UserDefaults.standard.set(roots, forKey: Self.rootsKey)
        startWatching()
    }

    // MARK: - 自动刷新（监听文件夹）

    /// 监听「导入来源」。老库可能没有 scanRoots（升级前导入的），
    /// 这时退回从素材路径反推出的目录，否则那些文件夹里的新增内容永远发现不了
    private func startWatching() {
        let roots = scanRoots.isEmpty ? libraryRoots : scanRoots
        if watcher == nil {
            watcher = FolderWatcher { [weak self] in
                Task { @MainActor in self?.autoRescan() }
            }
        }
        watcher?.update(roots: roots)
    }

    /// 手动点「重新扫描」：忽略冷却时间，并且没新素材时也给个反馈
    func refreshNow() {
        autoRescan(force: true)
    }

    /// 回到前台时补一次：睡眠期间的事件可能漏掉，外接盘拔插后
    /// FSEvents 也不一定能自己恢复（卷重挂会换设备节点）
    func applicationDidBecomeActive() {
        startWatching()
        autoRescan()
    }

    /// 增量扫描所有来源。和 `scanFolder` 的区别：
    /// 不写导入历史、不弹「导入完成」结果条——它可能一天触发几十次，写历史会把真正的导入记录冲掉
    func autoRescan(force: Bool = false) {
        guard !isScanning else { return }
        let roots = scanRoots.isEmpty ? libraryRoots : scanRoots
        guard !roots.isEmpty else { return }
        // 冷却：一次大量拷贝会触发多轮事件，扫完再被叫起来没有意义
        let now = Date()
        if !force, now.timeIntervalSince(lastAutoScanAt) < 20 { return }
        lastAutoScanAt = now

        isScanning = true
        Task { [weak self] in
            guard let self else { return }
            var added = 0
            var hitRoot: String?

            for root in roots {
                // 外接盘/网络盘可能已经拔了：跳过，别把它当成"这个目录空了"
                guard Self.isDirectory(root) else { continue }
                let scanner = MediaScanner(database: self.database)
                for await progress in scanner.scan(folder: URL(fileURLWithPath: root)) {
                    if case .finished(let newAssets, _, let ids) = progress.state {
                        added += newAssets
                        if !ids.isEmpty, hitRoot == nil { hitRoot = root }
                    }
                }
            }

            self.isScanning = false
            // 手动刷新时顺带补写漏迁的伴生文件：一次性迁移时外接盘没挂、
            // 素材文件读不到的那些，现在盘插回来了就一并补上（幂等，有 xmp 的自动跳过）
            if force { self.regenerateSidecars() }
            guard added > 0 else {
                if force { self.showAutoStatus("已是最新，没有发现新素材") }
                return
            }
            self.reloadAssets()
            self.resolveMissingPlaceNames()
            let folder = hitRoot.map { "「\(URL(fileURLWithPath: $0).lastPathComponent)」" } ?? ""
            self.showAutoStatus("\(folder)自动发现 \(added) 个新素材")
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private func showAutoStatus(_ text: String) {
        autoRefreshStatus = text
        autoRefreshStatusTask?.cancel()
        autoRefreshStatusTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            self?.autoRefreshStatus = nil
        }
    }

    /// 某个来源文件夹最近一次导入的时间，菜单/提示里显示
    func lastImportedAt(_ path: String) -> Date? {
        importHistory.first { $0.path == path }?.at
    }

    /// 没有导入历史时的兜底记录
    private var fallbackImport: ImportRecord?

    // MARK: - 派生数据缓存

    /// 这些都是 O(n) 甚至 O(n·m) 的计算。放在 computed property 里会被 SwiftUI
    /// **每次 body 重算** —— 8000 条素材时一个 hover 就能让主线程跑几十毫秒。
    /// 按 assetsVersion 失效，一次重算供多次渲染使用。
    private struct Derived {
        var roots: [String] = []
        var rootCounts: [String: Int] = [:]
        var sources: [(path: String, count: Int)] = []
        var duplicateCount: Int = 0
        var albumCounts: [String: Int] = [:]
        /// 拍摄地聚合：省组（可折叠）+ 无省平铺项（直辖市/海外）。侧边栏展示用
        var placeGroups: [SidebarPlaceGroup] = []
        var index: [Int64: Asset] = [:]      // id → 素材，避免线性查找
        var geotagged: [Asset] = []          // 带 GPS 的素材，地图页专用
        var order: [Int64: Int] = [:]        // id → 在 assets 里的下标，缩略图按窗口补齐时用
    }

    private var derived = Derived()
    private var derivedVersion: UInt64 = 0
    private var derivedStale = true

    private func invalidateDerived() {
        derivedStale = true
        assetsVersion &+= 1
    }

    private func currentDerived() -> Derived {
        if derivedStale || derivedVersion != assetsVersion {
            derived = buildDerived()
            derivedVersion = assetsVersion
            derivedStale = false
        }
        return derived
    }

    private func buildDerived() -> Derived {
        var d = Derived()
        d.index = Dictionary(uniqueKeysWithValues: assets.compactMap { a in
            a.id.map { ($0, a) }
        })

        // 来源文件夹：记录的导入目录 + 库里有素材但不被任何记录目录覆盖的目录
        var roots = scanRoots.filter { !$0.isEmpty }
        var dirs = Set(assets.map { ($0.filePath as NSString).deletingLastPathComponent })
        dirs.remove("")
        let uncovered = dirs.filter { dir in !roots.contains(where: { dir.hasPrefix($0) }) }
        roots.append(contentsOf: uncovered.sorted())
        d.roots = roots

        var counts: [String: Int] = [:]
        counts.reserveCapacity(roots.count)
        for a in assets {
            var best: String?
            for r in roots where a.filePath.hasPrefix(r) {
                if let b = best { if r.count > b.count { best = r } } else { best = r }
            }
            if let best { counts[best, default: 0] += 1 }
        }
        d.rootCounts = counts
        d.sources = roots.map { (path: $0, count: counts[$0] ?? 0) }

        d.duplicateCount = Self.countDuplicateGroups(assets)

        var albumCounts: [String: Int] = [:]
        for album in SmartAlbum.builtin() {
            albumCounts[album.id] = album.filter(assets).count
        }
        d.albumCounts = albumCounts

        d.placeGroups = Self.buildPlaceGroups(assets)

        d.geotagged = assets.filter { $0.latitude != nil && $0.longitude != nil }

        var order: [Int64: Int] = [:]
        order.reserveCapacity(assets.count)
        for (i, a) in assets.enumerated() {
            if let id = a.id { order[id] = i }
        }
        d.order = order
        return d
    }

    // MARK: - 对外派生数据

    var libraryRoots: [String] { currentDerived().roots }
    var rootAssetCounts: [String: Int] { currentDerived().rootCounts }
    var sourceItems: [(path: String, count: Int)] { currentDerived().sources }
    /// 重复素材的组数（侧边栏只显示数量，不建分组对象）
    var duplicateCount: Int { currentDerived().duplicateCount }
    var albumCounts: [String: Int] { currentDerived().albumCounts }
    /// 拍摄地聚合（按省分组 + 无省平铺），侧边栏折叠展示用
    var placeGroups: [SidebarPlaceGroup] {
        currentDerived().placeGroups
    }

    /// 按 id 取素材。原来 `assets.first { $0.id == id }` 是 O(n)，
    /// 选中态每帧都要查一次
    func asset(id: Int64) -> Asset? { currentDerived().index[id] }
    /// 带 GPS 的素材。地图页每次 body 都 filter 一遍 8000 条会拖垮主线程
    var geotaggedAssets: [Asset] { currentDerived().geotagged }

    func reloadAssets() {
        assets = (try? database.readAssets()) ?? []
        trashCount = ((try? database.readDeletedAssets()) ?? []).count
        invalidateDerived()
        rebuildFallbackImport()
        // 缩略图改成「滚到哪生成哪」（见 noteVisible），这里不再整库后台补齐：
        // 8000 条素材的补齐任务会长时间占着 CPU 和磁盘，反而让用户正看着的那几张更慢。
        // 只清掉失效缓存（旧键留下的孤儿文件）。回收站里的素材不在 assets 中，
        // 要一并算进"保留名单"，否则它们的缩略图每次启动都被清掉、进回收站又要重解一遍
        let keep = assets + ((try? database.readDeletedAssets()) ?? [])
        ThumbnailStore.shared.prune(keeping: keep)
    }

    // MARK: - 缩略图按需生成

    private var visibleIDs: Set<Int64> = []
    private var prewarmTask: Task<Void, Never>?

    /// 卡片滚进可视区时上报一次。真正要生成的缩略图由 cell 自己发起（只有它真的在屏幕上才发），
    /// 这里只顺手补**一屏以内**的前后几张，避免快速滚动时一片空白。
    /// 以前这里是 ±120（一次就是 240 条），启动和每次滚动停顿都会白解几百张看不见的图
    func noteVisible(_ id: Int64) {
        visibleIDs.insert(id)
        prewarmTask?.cancel()
        prewarmTask = Task { [weak self] in
            // 滚动停下 0.4s 再动手：快速拖动时不跟着跑
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.prewarmVisibleWindow()
        }
    }

    /// 只补当前可视位置附近的素材，不做全库
    private func prewarmVisibleWindow() {
        let ids = visibleIDs
        visibleIDs.removeAll(keepingCapacity: true)
        let order = currentDerived().order
        let indices = ids.compactMap { order[$0] }.sorted()
        guard let first = indices.first, let last = indices.last else { return }
        // 一屏大约 25 张，前后各留 10 张足够覆盖滚动时的空白
        let pad = 10
        let from = max(0, first - pad)
        let to = min(assets.count, last + pad)
        guard to > from else { return }
        ThumbnailStore.shared.prewarm(Array(assets[from..<to]))
    }

    // MARK: - 局部更新

    /// 评分/颜色/收藏这类小改动只改内存里那一条，不再整表重读重建网格
    private func patch(id: Int64, _ mutate: (inout Asset) -> Void) {
        guard let i = assets.firstIndex(where: { $0.id == id }) else { return }
        var a = assets[i]
        mutate(&a)
        assets[i] = a
        invalidateDerived()
    }

    /// 批量 patch：遍历一次 assets 命中所有 id，
    /// 别对每个 id 都调一次单条 patch（那是 O(n·m)）
    private func patch(ids: Set<Int64>, _ mutate: (inout Asset) -> Void) {
        guard !ids.isEmpty else { return }
        for i in assets.indices {
            guard let id = assets[i].id, ids.contains(id) else { continue }
            mutate(&assets[i])
        }
        invalidateDerived()
    }

    func setRating(id: Int64, rating: Int) {
        patch(id: id) { $0.rating = rating }
        try? database.updateRating(id: id, rating: rating)
        syncSidecars(ids: [id])
    }

    func setColorLabel(id: Int64, label: Int) {
        patch(id: id) { $0.colorLabel = label }
        try? database.updateColorLabel(id: id, label: label)
        syncSidecars(ids: [id])
    }

    func toggleFavorite(id: Int64) {
        guard let target = assets.first(where: { $0.id == id }) else { return }
        let next = !target.isFavorite
        patch(id: id) { $0.isFavorite = next }
        try? database.setFavorite(id: id, favorite: next)
        syncSidecars(ids: [id])
    }

    // MARK: - XMP sidecar（人工标注的真源）

    /// 把当前内存状态同步进素材旁的伴生文件。库只是索引，sidecar 才是真源——
    /// 不写这一步，换机/删库重扫后人工标注就没了。
    /// 读-合并-写盘放后台线程，批量几百条也不卡 UI；写失败（只读卷拔了之类）给出提示。
    private func syncSidecars(ids: [Int64], clearedLocation: Bool = false) {
        guard !ids.isEmpty else { return }
        let wanted = Set(ids)
        let requests: [SidecarService.WriteRequest] = assets.compactMap { a in
            guard let id = a.id, wanted.contains(id) else { return nil }
            return SidecarService.WriteRequest(
                filePath: a.filePath,
                fileHash: a.fileHash,
                fileName: a.fileName,
                latitude: a.latitude,
                longitude: a.longitude,
                placeName: a.placeName,
                rating: a.rating,
                colorLabel: a.colorLabel,
                isFavorite: a.isFavorite,
                forceCleared: clearedLocation
            )
        }
        guard !requests.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            let failures = SidecarService.apply(requests)
            guard failures > 0, let self else { return }
            let text = "\(failures) 个素材的标注没写入伴生文件（磁盘只读？），重建库可能丢"
            await MainActor.run { self.showAutoStatus(text) }
        }
    }

    // MARK: - 手动补定位

    /// 给一条素材补/改定位。placeName 留空会自动反查地名
    func setLocation(id: Int64, latitude: Double, longitude: Double, placeName: String? = nil) {
        setLocation(ids: [id], latitude: latitude, longitude: longitude, placeName: placeName)
    }

    /// 批量补定位：整批一个事务写库、一次内存 patch，地名只反查一次
    /// （几百条素材各自发一次 CLGeocoder 请求必被限流）
    func setLocation(ids: [Int64], latitude: Double, longitude: Double, placeName: String? = nil) {
        guard !ids.isEmpty else { return }
        let name = placeName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = (name?.isEmpty ?? true) ? nil : name
        patch(ids: Set(ids)) {
            $0.latitude = latitude
            $0.longitude = longitude
            $0.placeName = finalName
        }
        try? database.setLocation(ids: ids, latitude: latitude, longitude: longitude, placeName: finalName)
        syncSidecars(ids: ids)
        if finalName == nil { fillPlaceName(latitude: latitude, longitude: longitude, ids: ids) }
    }

    /// 清掉定位（填错了 / 不想标）。ids 可以是一批
    func clearLocation(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        patch(ids: Set(ids)) {
            $0.latitude = nil
            $0.longitude = nil
            $0.placeName = nil
        }
        try? database.setLocation(ids: ids, latitude: nil, longitude: nil, placeName: nil)
        // 必须写显式否定标记：素材文件里可能还有原生 GPS，
        // 单纯清库的话重建库时会冒回来
        syncSidecars(ids: ids, clearedLocation: true)
    }

    func clearLocation(id: Int64) { clearLocation(ids: [id]) }

    /// 反查地名后回填。CLGeocoder 有限流，这里只发一个请求、结果写给整批
    private func fillPlaceName(latitude: Double, longitude: Double, ids: [Int64]) {
        manualPlaceTask?.cancel()
        manualPlaceTask = Task { [weak self] in
            guard let name = await GeocodingService.shared.placeName(latitude: latitude,
                                                                     longitude: longitude) else { return }
            guard !Task.isCancelled else { return }
            self?.applyPlaceName(name, ids: ids)
        }
    }

    private func applyPlaceName(_ name: String, ids: [Int64]) {
        patch(ids: Set(ids)) { $0.placeName = name }
        try? database.setPlaceName(ids: ids, name: name)
        // 只同步手动补定位的反查结果；扫描期的批量反查（flushPlaceNames）不同步，
        // 否则会给所有带 GPS 的素材写 xmp，违背「只给人工编辑过的写」
        syncSidecars(ids: ids)
    }

    // MARK: - 存量标注迁移（一次性）

    /// 老库里的人工标注只存在 sqlite 里，重建库就没了。
    /// 一次性迁移：重新读素材文件的原生 GPS 与库值比对——对不上、
    /// 或文件里根本没有但库里有 → 判定为人工补的，写入伴生文件。
    /// 评分 / 色标 / 收藏天然是人工的，一并写入。
    private func migrateManualAnnotationsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.sidecarMigrationKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.sidecarMigrationKey)
        let snapshot = assets
        guard !snapshot.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            let written = Self.backfillSidecars(from: snapshot)
            guard written > 0, let self else { return }
            let text = "已把 \(written) 条人工标注写入伴生文件，重建库不再丢"
            await MainActor.run { self.showAutoStatus(text) }
        }
    }

    /// 手动重跑迁移：外接盘当时没挂上导致漏迁、或想强制补写时用。
    /// 幂等——已有伴生文件的素材会跳过，不会覆盖
    func regenerateSidecars() {
        let snapshot = assets
        guard !snapshot.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            let written = Self.backfillSidecars(from: snapshot)
            let text = written > 0 ? "已补写 \(written) 条标注到伴生文件" : "没有需要补写的标注"
            guard let self else { return }
            await MainActor.run { self.showAutoStatus(text) }
        }
    }

    /// 后台跑的纯函数：nonisolated，别继承类的 MainActor 隔离
    private nonisolated static func backfillSidecars(from assets: [Asset]) -> Int {
        var written = 0
        for a in assets {
            let url = URL(fileURLWithPath: a.filePath)
            // 外接盘拔了就跳过，别把它误判成「需要迁移」
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let ann = manualAnnotation(for: a, url: url) else { continue }
            if SidecarService.write(ann, for: url, fileHash: a.fileHash) { written += 1 }
        }
        return written
    }

    /// 判定哪些素材有人工标注：
    /// - 评分 / 色标 / 收藏非默认 → 一定是人工的
    /// - 有坐标、且与文件原生 GPS 不一致（或文件里读不出）→ 人工补的
    /// - 库里没坐标、文件里有原生 GPS → 可能是清除过、也可能只是老版本读取失败，
    ///   分不清就不动——宁可少迁一条，不要把可用 GPS 屏蔽掉
    private nonisolated static func manualAnnotation(for a: Asset, url: URL) -> SidecarAnnotation? {
        // 已有伴生文件（用户手工写的 / 之前迁过）不覆盖
        if SidecarService.exists(for: url, fileHash: a.fileHash) { return nil }

        let hasEdits = a.rating != 0 || a.colorLabel != 0 || a.isFavorite
        var manualLocation = false
        if let lat = a.latitude, let lon = a.longitude {
            if let native = nativeCoordinate(of: a, url: url) {
                manualLocation = abs(native.0 - lat) > 1e-6 || abs(native.1 - lon) > 1e-6
            } else {
                manualLocation = true
            }
        }
        guard hasEdits || manualLocation else { return nil }

        var ann = SidecarAnnotation()
        ann.fileName = a.fileName
        ann.fileHash = a.fileHash
        if manualLocation {
            ann.latitude = a.latitude
            ann.longitude = a.longitude
            if let p = a.placeName { ann.placeName = p }
        }
        if hasEdits {
            ann.rating = a.rating
            ann.colorLabel = a.colorLabel
            ann.isFavorite = a.isFavorite
        }
        return ann.hasContent ? ann : nil
    }

    /// 素材文件里的原生坐标。照片 / 实况走 EXIF；视频走 DJI 的 SRT 伴生字幕。
    /// （ISO6709 容器元数据要 async 读，这里读不到顶多多写一个内容相同的 xmp，无害）
    private nonisolated static func nativeCoordinate(of a: Asset, url: URL) -> (Double, Double)? {
        if !a.isVideo {
            guard let info = PhotoProbe.info(url: url),
                  let lat = info.latitude, let lon = info.longitude else { return nil }
            return (lat, lon)
        }
        guard let srt = DJINamingRule.srtSibling(for: url) else { return nil }
        return GPSParser.parseFirstCoordinate(from: srt)
    }

    func moveToTrash(id: Int64) {
        try? database.setDeleted(id: id, deleted: true)
        assets.removeAll { $0.id == id }
        invalidateDerived()
    }

    /// 批量移到回收站（多选后一次移入）。单个版本只是它的特例
    func moveToTrash(ids: [Int64]) {
        let set = Set(ids)
        guard !set.isEmpty else { return }
        try? database.setDeleted(ids: Array(set), deleted: true)
        assets.removeAll { guard let id = $0.id else { return false }; return set.contains(id) }
        invalidateDerived()
    }

    func restore(id: Int64) {
        try? database.setDeleted(id: id, deleted: false)
        reloadAssets()
    }

    // MARK: - 截取实况图

    /// 把「截取实况图」产出的「静帧 + 短视频」注册成一条实况照片素材入库。
    /// 静帧与被截视频同名（IMG_xxx.jpg + IMG_xxx.mp4），扫描期的配对逻辑会把它识别成
    /// 实况照片，这里再显式锁成 livePhoto + pairedVideoPath，确保悬停能播放那段动态。
    func importLivePhoto(photoPath: String, videoPath: String) async {
        let url = URL(fileURLWithPath: photoPath)
        guard let built = await MediaScanner.buildAsset(url: url) else { return }
        var live = built
        live.mediaType = MediaKind.livePhoto.rawValue
        live.pairedVideoPath = videoPath
        do { try database.save(&live) } catch { return }
        reloadAssets()
    }

    /// 设置「截取实况图」的提示，并在几秒后自动清除（避免遮挡界面）
    func reportGrab(_ message: String) {
        grabStatus = message
        let token = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if grabStatus == token { grabStatus = nil }
        }
    }

    // MARK: - 回收站清理

    /// 彻底清掉一条回收站记录。`deleteFile=true` 时连磁盘上的原文件一起删（不可恢复）
    func purge(_ asset: Asset, deleteFile: Bool) async {
        if deleteFile {
            await Task.detached(priority: .utility) { Self.removeFiles(of: asset) }.value
        }
        try? database.delete(ids: [asset.id].compactMap { $0 })
        ThumbnailStore.shared.invalidate(asset)
    }

    /// 清空回收站，返回被清掉的记录数。删文件走后台线程，几千条也不会冻住界面
    @discardableResult
    func emptyTrash(deleteFiles: Bool) async -> Int {
        let items = (try? database.readDeletedAssets()) ?? []
        guard !items.isEmpty else { return 0 }
        if deleteFiles {
            await Task.detached(priority: .utility) {
                for a in items { Self.removeFiles(of: a) }
            }.value
        }
        try? database.delete(ids: items.compactMap(\.id))
        for a in items { ThumbnailStore.shared.invalidate(a) }
        return items.count
    }

    /// 删素材对应的磁盘文件。实况照片抽到缓存目录里的动态视频是派生数据，
    /// 由缓存配额自己回收，不在这里处理
    nonisolated private static func removeFiles(of asset: Asset) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: asset.filePath)
        // iPhone 实况是「图片 + 同名 .MOV」两个文件，属于同一个素材，一起删
        if asset.kind == .livePhoto, let paired = asset.pairedVideoPath,
           paired != asset.filePath, !paired.contains("/Library/Caches/") {
            try? fm.removeItem(atPath: paired)
        }
    }

    // MARK: - 移除（只删索引，不动磁盘文件）

    /// 从素材库移除这些记录。磁盘上的原文件不受影响
    func removeAssets(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        try? database.delete(ids: ids)
        reloadAssets()
    }

    /// 移除整个来源文件夹。返回被移除的条数
    @discardableResult
    func removeSource(_ path: String) -> Int {
        let ids = assets.filter { $0.filePath.hasPrefix(path) }.compactMap { $0.id }
        removeAssets(ids: ids)
        scanRoots.removeAll { $0 == path }
        UserDefaults.standard.set(scanRoots, forKey: Self.rootsKey)
        startWatching()
        return ids.count
    }

    /// 内容重复的分组：同一段视频被从两个不同路径导入后，文件大小和时长会完全一致，
    /// 以此为指纹比 fileHash（含 mtime）可靠——拷贝出来的副本 mtime 是新的
    func duplicateGroups() -> [[Asset]] {
        var buckets: [String: [Asset]] = [:]
        for a in assets {
            buckets[Self.coarseKey(for: a), default: []].append(a)
        }
        // 只对粗筛命中的候选组做精筛。照片要读文件头，全库读一遍的话
        // 8000 张就是 2GB 磁盘 I/O + 主线程卡死
        var result: [[Asset]] = []
        // 注意判定用粗筛 key 前缀而非 kind：p- 桶 = 照片 + 实况照片（kind != video 且无时长）。
        // 实况照片曾因 kind 不是 .photo 而被当成视频桶整组判重——
        // 恰好同体积同分辨率的**不同**实况（华为机型常见）会被误报成重复。
        // 与 countDuplicateGroups 同一口径，两侧数字才能一致
        for (key, group) in buckets where group.count > 1 {
            if key.hasPrefix("p-") {
                var fine: [UInt64: [Asset]] = [:]
                for a in group {
                    fine[Self.headFingerprint(a.filePath), default: []].append(a)
                }
                result.append(contentsOf: fine.values.filter { $0.count > 1 })
            } else {
                result.append(group)
            }
        }
        return result.sorted { ($0.first?.fileName ?? "") < ($1.first?.fileName ?? "") }
    }

    /// 地名解析结果：省名（可能为空，如直辖市/海外）+ 市名（去掉尾部「市」）
    struct PlaceParts {
        var province: String?
        var city: String
    }

    /// 解析地名。库里的地名有两种来源格式：
    /// - 逆地理编码：省·市（如「广东省·广州」）；直辖市没有省，历史数据是「·重庆」这种空省前缀
    /// - 手工输入 / 历史遗留：纯市名（如「广州市」）
    /// 统一提取为 (省?, 市)，市名去掉尾部「市」，让新旧格式能按市名聚合
    static func placeParts(of placeName: String) -> PlaceParts {
        let trimmed = placeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dot = trimmed.firstIndex(of: "·") {
            let province = trimmed[..<dot]
            let city = trimmed[trimmed.index(after: dot)...]
            return PlaceParts(province: province.isEmpty ? nil : String(province),
                              city: cityWithoutSuffix(String(city)))
        }
        return PlaceParts(province: nil, city: cityWithoutSuffix(trimmed))
    }

    /// 取地名里的市名（无省信息则整名），拍摄地筛选按它匹配：
    /// 「广东省·广州」与「广州市」（历史遗留）都归一为「广州」，点一下全出来
    static func city(of placeName: String?) -> String? {
        guard let p = placeName, !p.isEmpty else { return nil }
        return placeParts(of: p).city
    }

    private static func cityWithoutSuffix(_ s: String) -> String {
        s.hasSuffix("市") ? String(s.dropLast()) : s
    }

    /// 把地名聚合成侧边栏条目：先按市名合并（「广东省·广州」+「广州市」=「广州」），
    /// 再按省份分组；没有省份的（直辖市、海外地名）成为独立平铺项。
    /// 组/行按素材总数降序。
    static func buildPlaceGroups(_ assets: [Asset]) -> [SidebarPlaceGroup] {
        var cityCounts: [String: Int] = [:]
        var provinceOfCity: [String: String] = [:]
        for a in assets {
            guard let pn = a.placeName, !pn.isEmpty else { continue }
            let parts = placeParts(of: pn)
            cityCounts[parts.city, default: 0] += 1
            if let p = parts.province { provinceOfCity[parts.city] = p }
        }
        guard !cityCounts.isEmpty else { return [] }

        var byProvince: [String: [(city: String, count: Int)]] = [:]
        var standalone: [(city: String, count: Int)] = []
        for (city, count) in cityCounts {
            if let province = provinceOfCity[city] {
                byProvince[province, default: []].append((city: city, count: count))
            } else {
                standalone.append((city: city, count: count))
            }
        }

        var groups: [SidebarPlaceGroup] = []
        for (province, cities) in byProvince {
            let sorted = cities.sorted { $0.count > $1.count }
            let total = sorted.reduce(0) { $0 + $1.count }
            groups.append(SidebarPlaceGroup(province: province, total: total, cities: sorted))
        }
        for item in standalone {
            groups.append(SidebarPlaceGroup(province: nil, total: item.count,
                                            cities: [(item.city, item.count)]))
        }
        return groups.sorted { $0.total > $1.total }
    }

    /// 只要组数不要分组内容（侧边栏计数用），省掉建数组和排序
    private static func countDuplicateGroups(_ assets: [Asset]) -> Int {
        var buckets: [String: Int] = [:]
        for a in assets {
            buckets[Self.coarseKey(for: a), default: 0] += 1
        }
        var count = 0
        for (key, n) in buckets where n > 1 {
            // 照片组还要按文件头细分，可能比粗筛组数更多，也可能更少
            if key.hasPrefix("p-") {
                let group = assets.filter { Self.coarseKey(for: $0) == key }
                var seen = Set<UInt64>()
                var dupKeys = Set<UInt64>()
                for a in group {
                    let fp = Self.headFingerprint(a.filePath)
                    if !seen.insert(fp).inserted { dupKeys.insert(fp) }
                }
                count += dupKeys.count
            } else {
                count += 1
            }
        }
        return count
    }

    /// 粗筛键：纯内存计算，不碰磁盘。视频看「大小 + 时长」，照片看「大小 + 宽高」
    private static func coarseKey(for a: Asset) -> String {
        let size = "\(a.fileSize)"
        if a.kind == .video || a.durationSeconds > 0 {
            return "v-\(size)-\(Int((a.durationSeconds * 1000).rounded()))"
        }
        return "p-\(size)-\(a.width)x\(a.height)"
    }

    /// 读文件开头 256KB 算 FNV：两张真重复的照片头必然一致，成本也就一次小读盘
    private static func headFingerprint(_ path: String) -> UInt64 {
        guard let handle = FileHandle(forReadingAtPath: path) else { return 0 }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 256 * 1024)
        var hash: UInt64 = 14695981039346656037
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return hash
    }

    /// 每组保留最早入库的那一个，其余作为重复项返回
    func redundantIDs(in group: [Asset]) -> [Int64] {
        guard let keeper = group.min(by: { $0.createdAt < $1.createdAt }) else { return [] }
        return group.filter { $0.id != keeper.id }.compactMap { $0.id }
    }

    // MARK: - 扫描

    func scanFolder(_ url: URL) {
        guard !isScanning else { return }
        addScanRoot(url.path)
        isScanning = true
        Task {
            let scanner = MediaScanner(database: database)
            for await progress in scanner.scan(folder: url) {
                scanProgress = progress
                if case .finished(let added, let dup, let ids) = progress.state {
                    isScanning = false
                    // 写进历史并落盘：否则重启后「最近导入」和新增 id 全没了
                    importHistory.insert(
                        ImportRecord(path: url.path, at: Date(),
                                     added: added, duplicates: dup, ids: ids),
                        at: 0)
                    saveHistory()
                    reloadAssets()
                    resolveMissingPlaceNames()
                    // 结果条留一会儿再自动收起，之前 isScanning 一置 false 就立刻消失，等于没提示
                    scheduleStatusDismiss()
                }
            }
        }
    }

    private var statusDismissTask: Task<Void, Never>?

    private func scheduleStatusDismiss() {
        statusDismissTask?.cancel()
        statusDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            self?.scanProgress = nil
        }
    }

    func dismissScanStatus() {
        statusDismissTask?.cancel()
        scanProgress = nil
    }

    /// 扫描完成后补地名。CLGeocoder 有请求频率限制，必须串行 + 间隔，
    /// 否则几百个素材一次性并发请求会全部失败，还会把主线程拖住。
    ///
    /// 8000 张手机照片几乎张张带 GPS，逐条处理有两个致命点：
    /// ① 请求数量爆炸；② 每解析完一条就 patch 一次，@Published 一变整个网格 8000 个
    /// cell 就要重 diff。所以按坐标去重（手机相册往往集中在少数几个地方），
    /// 并且攒够一批再统一写回内存。
    private func resolveMissingPlaceNames() {
        placeNameTask?.cancel()
        placeNameTask = Task { [weak self] in
            guard let self else { return }
            var byCoord: [String: (lat: Double, lon: Double, ids: [Int64])] = [:]
            for a in self.assets where a.placeName == nil {
                guard let id = a.id, let lat = a.latitude, let lon = a.longitude else { continue }
                // 3 位小数 ≈ 100m，同一个地方的照片合并成一个请求
                let key = String(format: "%.3f,%.3f", lat, lon)
                byCoord[key, default: (lat, lon, [])].ids.append(id)
            }

            var pending: [Int64: String] = [:]
            var resolved = 0
            for (_, item) in byCoord {
                guard !Task.isCancelled else { break }
                guard let name = await GeocodingService.shared.placeName(latitude: item.lat,
                                                                        longitude: item.lon) else { continue }
                for id in item.ids {
                    try? self.database.setPlaceName(id: id, name: name)
                    pending[id] = name
                }
                resolved += 1
                // 攒一批再写内存，避免每次都触发整库重绘
                if pending.count >= 200 {
                    self.flushPlaceNames(pending)
                    pending.removeAll()
                }
                if resolved >= 400 { break }    // 一次别贪多，剩下的下次导入再补
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            self.flushPlaceNames(pending)
        }
    }

    private func flushPlaceNames(_ map: [Int64: String]) {
        guard !map.isEmpty else { return }
        for i in assets.indices {
            guard let id = assets[i].id, let name = map[id] else { continue }
            assets[i].placeName = name
        }
        invalidateDerived()
    }
}

struct ScanProgress: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case discovering
        case importing(indexed: Int, total: Int?)
        case finished(newAssets: Int, duplicates: Int, newIDs: [Int64])
    }
    let state: State
    let currentFile: String?
}

/// 一次导入的记录：落盘保存，重启后「最近导入」和新增 id 都还在
struct ImportRecord: Codable, Equatable {
    let path: String
    let at: Date
    let added: Int
    let duplicates: Int
    /// 本次真正新增的素材 id
    let ids: [Int64]
}
