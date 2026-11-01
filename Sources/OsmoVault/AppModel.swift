import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var assets: [Asset] = []
    @Published var isScanning = false
    @Published var scanProgress: ScanProgress?
    /// 导入过的文件夹，最近导入的在前
    @Published private(set) var scanRoots: [String] = []

    let database: AppDatabase
    private var placeNameTask: Task<Void, Never>?
    private static let rootsKey = "OsmoVault.scanRoots"

    init() {
        self.database = (try? AppDatabase.open()) ?? AppDatabase.inMemory()
        self.scanRoots = UserDefaults.standard.stringArray(forKey: Self.rootsKey) ?? []
        reloadAssets()
    }

    // MARK: - 来源文件夹

    /// 侧边栏顶部展示的来源文件夹。没有导入记录时（比如升级前就建好的库）从素材路径反推
    var libraryRoots: [String] {
        if !scanRoots.isEmpty { return scanRoots }
        if let derived = Self.commonRoot(of: assets.map(\.filePath)) { return [derived] }
        return []
    }

    private func addScanRoot(_ path: String) {
        var roots = scanRoots.filter { $0 != path }
        roots.insert(path, at: 0)
        scanRoots = roots
        UserDefaults.standard.set(roots, forKey: Self.rootsKey)
    }

    /// 取所有素材所在目录的最长公共前缀
    private static func commonRoot(of filePaths: [String]) -> String? {
        let dirs = filePaths.map { ($0 as NSString).deletingLastPathComponent }
        guard var root = dirs.first, !root.isEmpty else { return nil }
        for d in dirs.dropFirst() { root = commonPrefix(root, d) }
        // 退化到 "/" 说明素材分散在互不相干的盘符下，这时退回素材最多的那个目录
        if root == "/" { return mostCommonDirectory(dirs) }
        return root
    }

    private static func commonPrefix(_ a: String, _ b: String) -> String {
        if a == b { return a }
        let ac = a.split(separator: "/"), bc = b.split(separator: "/")
        var out: [String] = []
        for i in 0..<min(ac.count, bc.count) {
            if ac[i] == bc[i] { out.append(String(ac[i])) } else { break }
        }
        return "/" + out.joined(separator: "/")
    }

    private static func mostCommonDirectory(_ dirs: [String]) -> String? {
        let counted = Dictionary(grouping: dirs, by: { $0 }).mapValues(\.count)
        return counted.max(by: { $0.value < $1.value })?.key
    }

    func reloadAssets() {
        assets = (try? database.readAssets()) ?? []
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

    // MARK: - 扫描

    func scanFolder(_ url: URL) {
        guard !isScanning else { return }
        addScanRoot(url.path)
        isScanning = true
        Task {
            let scanner = MediaScanner(database: database)
            for await progress in scanner.scan(folder: url) {
                scanProgress = progress
                if case .finished = progress.state {
                    isScanning = false
                    reloadAssets()
                    resolveMissingPlaceNames()
                }
            }
        }
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

struct ScanProgress: Equatable {
    enum State: Equatable {
        case discovering
        case importing(indexed: Int, total: Int?)
        case finished(newAssets: Int, duplicates: Int)
    }
    let state: State
    let currentFile: String?
}
