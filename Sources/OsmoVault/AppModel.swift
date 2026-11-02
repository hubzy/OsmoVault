import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var assets: [Asset] = []
    /// 素材集合的版本号。视图用它判断缓存的分组结果要不要重算，
    /// 不用去比较 8000 条 Asset（值类型，逐条 Equatable 太贵）
    @Published private(set) var assetsVersion: UInt64 = 0
    @Published var isScanning = false
    @Published var scanProgress: ScanProgress?
    /// 导入过的文件夹，最近导入的在前
    @Published private(set) var scanRoots: [String] = []
    /// 导入历史（持久化）：最近一次在前，重启后「最近导入」仍在
    @Published private(set) var importHistory: [ImportRecord] = []

    let database: AppDatabase
    private var placeNameTask: Task<Void, Never>?
    /// 手动补定位后的地名反查，与扫描期的地名任务分开，互不取消
    private var manualPlaceTask: Task<Void, Never>?
    private static let rootsKey = "OsmoVault.scanRoots"
    private static let historyKey = "OsmoVault.importHistory"

    /// 最近一次导入记录（可能来自上一次启动）
    var lastImport: ImportRecord? { importHistory.first ?? fallbackImport }
    /// 最近一次导入新增的素材 id
    var lastImportIDs: [Int64] { lastImport?.ids ?? [] }

    init() {
        self.database = (try? AppDatabase.open()) ?? AppDatabase.inMemory()
        self.scanRoots = UserDefaults.standard.stringArray(forKey: Self.rootsKey) ?? []
        self.importHistory = Self.loadHistory()
        reloadAssets()
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
        var places: [(name: String, count: Int)] = []
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

        let grouped = Dictionary(grouping: assets.compactMap(\.placeName), by: { $0 })
        d.places = grouped.map { ($0.key, $0.value.count) }.sorted { $0.count > $1.count }

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
    var places: [(name: String, count: Int)] { currentDerived().places }

    /// 按 id 取素材。原来 `assets.first { $0.id == id }` 是 O(n)，
    /// 选中态每帧都要查一次
    func asset(id: Int64) -> Asset? { currentDerived().index[id] }
    /// 带 GPS 的素材。地图页每次 body 都 filter 一遍 8000 条会拖垮主线程
    var geotaggedAssets: [Asset] { currentDerived().geotagged }

    func reloadAssets() {
        assets = (try? database.readAssets()) ?? []
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
    }

    func setColorLabel(id: Int64, label: Int) {
        patch(id: id) { $0.colorLabel = label }
        try? database.updateColorLabel(id: id, label: label)
    }

    func toggleFavorite(id: Int64) {
        guard let target = assets.first(where: { $0.id == id }) else { return }
        let next = !target.isFavorite
        patch(id: id) { $0.isFavorite = next }
        try? database.setFavorite(id: id, favorite: next)
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
        for group in buckets.values where group.count > 1 {
            if group.contains(where: { $0.kind == .photo && $0.durationSeconds <= 0 }) {
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
