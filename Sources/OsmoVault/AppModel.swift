import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var assets: [Asset] = []
    @Published var isScanning = false
    @Published var scanProgress: ScanProgress?
    /// 导入过的文件夹，最近导入的在前
    @Published private(set) var scanRoots: [String] = []
    /// 导入历史（持久化）：最近一次在前，重启后「最近导入」仍在
    @Published private(set) var importHistory: [ImportRecord] = []

    let database: AppDatabase
    private var placeNameTask: Task<Void, Never>?
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

    /// 来源文件夹：记录的导入目录 + 库里有素材但不被任何记录目录覆盖的目录
    /// （老版本导入的内容没有记录，只能从素材路径反推出来，否则会凭空少一个来源）
    var libraryRoots: [String] {
        var roots = scanRoots.filter { !$0.isEmpty }
        let dirs = Set(assets.map { ($0.filePath as NSString).deletingLastPathComponent })
            .filter { !$0.isEmpty }
        let uncovered = dirs.filter { d in !roots.contains(where: { d.hasPrefix($0) }) }
        roots.append(contentsOf: uncovered.sorted())
        return roots
    }

    private func addScanRoot(_ path: String) {
        var roots = scanRoots.filter { $0 != path }
        roots.insert(path, at: 0)
        scanRoots = roots
        UserDefaults.standard.set(roots, forKey: Self.rootsKey)
    }

    /// 各来源文件夹下的素材数。路径有包含关系时按最长前缀匹配，避免计入更上层目录
    var rootAssetCounts: [String: Int] {
        var counts: [String: Int] = [:]
        let roots = libraryRoots
        for a in assets {
            var best: String?
            for r in roots where a.filePath.hasPrefix(r) {
                if let b = best { if r.count > b.count { best = r } } else { best = r }
            }
            if let best { counts[best, default: 0] += 1 }
        }
        return counts
    }

    /// 侧边栏「导入来源」用：文件夹 → 素材数
    var sourceItems: [(path: String, count: Int)] {
        let counts = rootAssetCounts
        return libraryRoots.map { (path: $0, count: counts[$0] ?? 0) }
    }

    /// 某个来源文件夹最近一次导入的时间，菜单/提示里显示
    func lastImportedAt(_ path: String) -> Date? {
        importHistory.first { $0.path == path }?.at
    }

    /// 没有导入历史时的兜底记录
    private var fallbackImport: ImportRecord?

    func reloadAssets() {
        assets = (try? database.readAssets()) ?? []
        rebuildFallbackImport()
        // 后台补齐缺失的缩略图 + 清掉失效缓存（旧键留下的孤儿文件）
        ThumbnailStore.shared.prewarm(assets)
        ThumbnailStore.shared.prune(keeping: assets)
    }

    // MARK: - 局部更新

    /// 评分/颜色/收藏这类小改动只改内存里那一条，不再整表重读重建网格
    private func patch(id: Int64, _ mutate: (inout Asset) -> Void) {
        guard let i = assets.firstIndex(where: { $0.id == id }) else { return }
        var a = assets[i]
        mutate(&a)
        assets[i] = a
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

    func moveToTrash(id: Int64) {
        try? database.setDeleted(id: id, deleted: true)
        assets.removeAll { $0.id == id }
    }

    func restore(id: Int64) {
        try? database.setDeleted(id: id, deleted: false)
        reloadAssets()
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
            let key = "\(a.fileSize)-\(Int((a.durationSeconds * 1000).rounded()))"
            buckets[key, default: []].append(a)
        }
        return buckets.values
            .filter { $0.count > 1 }
            .sorted { ($0.first?.fileName ?? "") < ($1.first?.fileName ?? "") }
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
    private func resolveMissingPlaceNames() {
        placeNameTask?.cancel()
        placeNameTask = Task { [weak self] in
            guard let self else { return }
            for asset in self.assets where asset.placeName == nil {
                guard let lat = asset.latitude, let lon = asset.longitude, let id = asset.id else { continue }
                guard !Task.isCancelled else { return }
                if let name = await GeocodingService.shared.placeName(latitude: lat, longitude: lon) {
                    try? self.database.setPlaceName(id: id, name: name)
                    self.patch(id: id) { $0.placeName = name }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
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
