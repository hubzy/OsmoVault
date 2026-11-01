import Foundation
import AVFoundation
import AppKit

/// 异步缩略图生成 + 内存/磁盘双级缓存（磁盘目录 ~/Library/Caches/OsmoVault/thumbnails）
///
/// 设计要点（滚动流畅的关键）：
/// - `thumbnail(for:)` 是 async 的，直接把图返回给调用方，而不是靠通知"广播"
/// - `memory` 缓存已解码的 NSImage，滚动回头不用再读盘、再解码
/// - `limiter` 限制同时解码的视频数量，避免几十个 AVAssetImageGenerator 抢 CPU 把界面拖卡
/// - `prewarm` 后台补齐整库缩略图，不用滚到才生成
@MainActor
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    private let cacheDir: URL
    private let memory = NSCache<NSString, NSImage>()
    /// 详情页用的大图缓存，单独一份且容量小：整张原图常驻内存会把内存吃穿
    private let largeMemory = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let limiter = DecodeLimiter(limit: 3)
    private var prewarmTask: Task<Void, Never>?

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = caches.appendingPathComponent("OsmoVault/thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        memory.countLimit = 600
        largeMemory.countLimit = 8
    }

    // MARK: - 对外接口

    /// 取缩略图：内存命中直接返回；否则读磁盘缓存；再没有才解码视频帧
    func thumbnail(for asset: Asset) async -> NSImage? {
        let key = Self.cacheKey(for: asset)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if let running = inFlight[key] { return await running.value }

        let task = makeTask(key: key, path: asset.filePath)
        inFlight[key] = task
        // 调用方被取消（比如卡片滚出可视区）时也要清掉登记表，否则会一直堆积
        defer { inFlight[key] = nil }
        return await task.value
    }

    /// 详情页看照片用：解码到最长边 1600 就够看了，不必把几十 MB 的原图整个展开
    func largeImage(for asset: Asset) async -> NSImage? {
        let key = "large-\(Self.cacheKey(for: asset))"
        if let hit = largeMemory.object(forKey: key as NSString) { return hit }
        guard let image = await Self.renderLarge(path: asset.filePath) else { return nil }
        largeMemory.setObject(image, forKey: key as NSString)
        return image
    }

    /// 只取**已经生成好**的缩略图（内存或磁盘），绝不触发解码。
    /// 详情页翻图时先拿它顶上，避免大图解码期间白屏；顺带不占 DecodeLimiter 的名额
    func cachedThumbnail(for asset: Asset) -> NSImage? {
        let key = Self.cacheKey(for: asset)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        let dest = cacheDir.appendingPathComponent(key + ".jpg")
        guard let data = try? Data(contentsOf: dest),
              let image = NSImage(data: data) else { return nil }
        memory.setObject(image, forKey: key as NSString)
        return image
    }

    /// 素材被替换/删除后清掉对应缓存
    func invalidate(_ asset: Asset) {
        let key = Self.cacheKey(for: asset)
        memory.removeObject(forKey: key as NSString)
        inFlight[key]?.cancel()
        inFlight[key] = nil
        try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(key + ".jpg"))
    }

    /// 后台补齐缺失的缩略图，整库慢慢填满，不用滚到哪才生成哪
    /// 只在磁盘上没有时才真正解码，已有缓存的素材几乎零成本跳过
    func prewarm(_ assets: [Asset]) {
        prewarmTask?.cancel()
        let dir = cacheDir
        let keysAndPaths = assets.map { (Self.cacheKey(for: $0), $0.filePath) }

        prewarmTask = Task { [weak self] in
            // 每批 4 个并发，批间让出主线程，不跟界面抢
            for chunk in keysAndPaths.chunked(into: 4) {
                if Task.isCancelled { return }
                await withTaskGroup(of: Void.self) { group in
                    for (key, path) in chunk {
                        group.addTask {
                            let exists = await Task.detached(priority: .background) {
                                FileManager.default.fileExists(atPath: dir.appendingPathComponent(key + ".jpg").path)
                            }.value
                            guard !exists else { return }
                            _ = await self?.renderOnly(key: key, path: path)
                        }
                    }
                }
            }
        }
    }

    /// 清掉不属于当前素材库的缓存文件（旧键、已删除素材留下的孤儿文件）
    func prune(keeping assets: [Asset]) {
        let keep = Set(assets.map { Self.cacheKey(for: $0) + ".jpg" })
        let dir = cacheDir
        Task.detached(priority: .background) {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            var removed = 0
            for f in files where f.hasSuffix(".jpg") && !keep.contains(f) {
                try? fm.removeItem(at: dir.appendingPathComponent(f))
                removed += 1
            }
            if removed > 0 { print("[OsmoVault] 清理失效缩略图缓存 \(removed) 个") }
        }
    }

    // MARK: - 内部实现

    /// 只做后台补齐，不占用 inFlight 登记表、也不往内存缓存塞（避免整库图片常驻内存）
    private func renderOnly(key: String, path: String) async -> NSImage? {
        let dest = cacheDir.appendingPathComponent(key + ".jpg")
        let limiter = self.limiter
        await limiter.acquire()
        defer { Task.detached { await limiter.release() } }
        return await Self.render(path: path, to: dest)
    }

    private func makeTask(key: String, path: String) -> Task<NSImage?, Never> {
        let dest = cacheDir.appendingPathComponent(key + ".jpg")
        let limiter = limiter
        let memory = memory
        return Task<NSImage?, Never> { () -> NSImage? in
            if let disk = await Self.loadFromDisk(dest) {
                memory.setObject(disk, forKey: key as NSString)
                return disk
            }
            await limiter.acquire()
            defer { Task.detached { await limiter.release() } }
            guard let image = await Self.render(path: path, to: dest) else { return nil }
            // 调用方可能已经被取消，这里仍然落内存缓存，下次进来直接命中
            memory.setObject(image, forKey: key as NSString)
            return image
        }
    }

    /// 缓存键必须**跨进程稳定**。
    /// 之前用 `String.hashValue`，而 Swift 的哈希种子每次进程启动都会随机化，
    /// 导致同一个素材每次启动都算出新键 —— 磁盘缓存 100% 未命中，只能重新解码 4K 视频，
    /// 缓存目录里同一个素材会被反复写入几十份（实测 156 个素材攒出 2353 个文件 / 194MB）。
    /// 这里改成 FNV-1a，纯计算、不依赖运行时的随机种子。
    private static func cacheKey(for asset: Asset) -> String {
        "\(fnv1a(asset.filePath))-\(asset.fileHash)"
    }

    /// FNV-1a 64 位：确定性哈希，同一字符串在任何进程里都得到同一个值
    private static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211   // FNV prime
        }
        return hash
    }

    private static func loadFromDisk(_ url: URL) async -> NSImage? {
        await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let image = NSImage(data: data) else { return nil }
            _ = image.size   // 触发一次尺寸解析，避免首帧绘制时才解码
            return image
        }.value
    }

    private static func render(path: String, to dest: URL) async -> NSImage? {
        await Task.detached(priority: .utility) { () -> NSImage? in
            // 照片走 ImageIO 直接取缩略图，比解码一帧视频快一个量级；
            // 实况照片也用静态图部分，动态部分只在 hover / 详情里才解
            if let image = Self.renderImage(path: path, to: dest) { return image }

            let avAsset = AVURLAsset(url: URL(fileURLWithPath: path))
            let gen = AVAssetImageGenerator(asset: avAsset)
            gen.appliesPreferredTrackTransform = true
            // 网格卡片只有 ~200pt 宽，400px 足够，解码开销比 640 再降一截
            gen.maximumSize = CGSize(width: 400, height: 400)
            // 放宽时间容差：只为取一帧代表图，精确寻帧会让解码器多读很多帧
            gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

            let duration = (try? await avAsset.load(.duration)) ?? .invalid
            let seconds = duration.isNumeric ? CMTimeGetSeconds(duration) : 0
            let target = CMTime(seconds: min(max(seconds * 0.35, 0.1), 10), preferredTimescale: 600)

            guard let cg = try? gen.copyCGImage(at: target, actualTime: nil) else { return nil }
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            Self.writeJPEG(image, to: dest)
            return image
        }.value
    }

    nonisolated private static func renderLarge(path: String) async -> NSImage? {
        await Task.detached(priority: .utility) { () -> NSImage? in
            let url = URL(fileURLWithPath: path)
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                // 详情里偶尔会连续翻图，缓存住解码结果能明显减少等待
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
    }

    /// 图片缩略图：让 ImageIO 直接生成缩略图（会带 EXIF 方向），非图片返回 nil
    nonisolated private static func renderImage(path: String, to dest: URL) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard MediaScanner.imageExtensions.contains(url.pathExtension.lowercased()),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // 按 EXIF 方向摆正
            kCGImageSourceThumbnailMaxPixelSize: 400
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        Self.writeJPEG(image, to: dest)
        return image
    }

    nonisolated private static func writeJPEG(_ image: NSImage, to dest: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else { return }
        try? jpeg.write(to: dest)
    }
}

/// 并发闸门：同时最多 N 个视频在解码
private actor DecodeLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        running += 1
    }

    func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()   // 直接把名额交给等待者，running 不变
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
