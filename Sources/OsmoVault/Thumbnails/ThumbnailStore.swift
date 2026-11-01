import Foundation
import AVFoundation
import AppKit

/// 异步缩略图生成 + 内存/磁盘双级缓存（磁盘目录 ~/Library/Caches/OsmoVault/thumbnails）
///
/// 设计要点（滚动流畅的关键）：
/// - `thumbnail(for:)` 是 async 的，直接把图返回给调用方，而不是靠通知"广播"
/// - `memory` 缓存已解码的 NSImage，滚动回头不用再读盘、再解码
/// - `limiter` 限制同时解码的视频数量，避免几十个 AVAssetImageGenerator 抢 CPU 把界面拖卡
@MainActor
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    private let cacheDir: URL
    private let memory = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let limiter = DecodeLimiter(limit: 3)

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = caches.appendingPathComponent("OsmoVault/thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        memory.countLimit = 600
    }

    // MARK: - 对外接口

    /// 取缩略图：内存命中直接返回；否则读磁盘缓存；再没有才解码视频帧
    func thumbnail(for asset: Asset) async -> NSImage? {
        let key = cacheKey(for: asset)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if let running = inFlight[key] { return await running.value }

        let dest = cacheDir.appendingPathComponent(key + ".jpg")
        let path = asset.filePath
        let limiter = limiter

        let task = Task<NSImage?, Never> { () -> NSImage? in
            if let disk = await Self.loadFromDisk(dest) { return disk }
            await limiter.acquire()
            defer { Task.detached { await limiter.release() } }
            return await Self.render(path: path, to: dest)
        }

        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { memory.setObject(image, forKey: key as NSString) }
        return image
    }

    /// 素材被替换/删除后清掉对应缓存
    func invalidate(_ asset: Asset) {
        let key = cacheKey(for: asset)
        memory.removeObject(forKey: key as NSString)
        inFlight[key]?.cancel()
        inFlight[key] = nil
        try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(key + ".jpg"))
    }

    // MARK: - 内部实现

    private func cacheKey(for asset: Asset) -> String {
        // 用路径+大小做缓存键，避开非法文件名字符
        asset.fileHash + "-" + String(abs(asset.filePath.hashValue))
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
            if let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) {
                try? jpeg.write(to: dest)
            }
            return image
        }.value
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
