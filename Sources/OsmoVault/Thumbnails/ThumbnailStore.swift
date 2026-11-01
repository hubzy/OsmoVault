import Foundation
import AVFoundation
import AppKit

/// 异步缩略图生成与磁盘缓存（存 ~/Library/Caches/OsmoVault/thumbnails）
@MainActor
final class ThumbnailStore: ObservableObject {
    static let shared = ThumbnailStore()

    @Published private var loaded: Set<String> = []
    private let cacheDir: URL
    private var generating: Set<String> = []
    private let queue = DispatchQueue(label: "thumbnail", qos: .userInitiated)

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = caches.appendingPathComponent("OsmoVault/thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    private func cacheURL(for asset: Asset) -> URL {
        // 用路径+大小做缓存键，避开非法文件名字符
        let key = asset.fileHash + "-" + String(abs(asset.filePath.hashValue))
        return cacheDir.appendingPathComponent(key + ".jpg")
    }

    /// 返回缓存的缩略图；没有则触发后台生成，生成完发布通知
    func thumbnail(for asset: Asset) -> NSImage? {
        let url = cacheURL(for: asset)
        if let img = NSImage(contentsOf: url) { return img }
        if generating.contains(asset.filePath) { return nil }
        generating.insert(asset.filePath)
        let dest = url
        let src = asset.filePath
        queue.async {
            let avAsset = AVURLAsset(url: URL(fileURLWithPath: src))
            let gen = AVAssetImageGenerator(asset: avAsset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 640, height: 640)
            // 取中间帧，比首帧更有代表性
            let duration = CMTimeGetSeconds(gen.asset.duration)
            let mid = CMTime(seconds: max(duration * 0.5, 0.1), preferredTimescale: 600)
            if let cg = try? gen.copyCGImage(at: mid, actualTime: nil) {
                let rep = NSBitmapImageRep(cgImage: cg)
                if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                    try? data.write(to: dest)
                }
            }
            Task { @MainActor in
                self.generating.remove(src)
                self.loaded.insert(src)  // 触发依赖 loaded 的视图刷新
            }
        }
        return nil
    }
}

