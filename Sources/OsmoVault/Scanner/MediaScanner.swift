import Foundation
import AVFoundation
import GRDB

struct MediaScanner {
    let database: AppDatabase

    func scan(folder: URL) -> AsyncStream<ScanProgress> {
        AsyncStream { continuation in
            // 必须 detached：用 Task 会继承调用方的 MainActor，整个扫描（读几百个 4K 文件的
            // 时长/分辨率）会堵住主线程，进度条一帧都渲染不出来，看着就像"什么都没发生"
            let task = Task.detached(priority: .utility) {
                var newCount = 0
                var dupCount = 0
                var newIDs: [Int64] = []     // 本次真正新增的 id
                continuation.yield(ScanProgress(state: .discovering, currentFile: nil))

                let media = Self.discoverMedia(in: folder)
                // iPhone 导出的实况照片是"同名图片 + 同名短视频"，先找出这些配对，
                // 配对上的视频不再单独入库，否则同一个实况会在库里出两张卡片
                let pairedVideos = Self.livePhotoPairs(images: media.images, videos: media.videos)
                let files = (media.images + media.videos).sorted { $0.path < $1.path }
                let total = files.count

                for (index, url) in files.enumerated() {
                    try Task.checkCancellation()
                    if pairedVideos.contains(url.path) { continue }

                    let fp = Self.fingerprint(of: url)
                    let isDup = (try? database.hasAny(filePath: url.path, fingerprint: fp)) ?? false
                    if isDup {
                        dupCount += 1
                    } else {
                        var asset = Self.buildAsset(url: url, fingerprint: fp)
                        try? database.save(&asset)
                        newCount += 1
                        if let id = asset.id { newIDs.append(id) }
                    }
                    continuation.yield(ScanProgress(state: .importing(indexed: index + 1, total: total),
                                                    currentFile: url.lastPathComponent))
                }
                continuation.yield(ScanProgress(state: .finished(newAssets: newCount, duplicates: dupCount, newIDs: newIDs), currentFile: nil))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 发现文件

    /// 手机相册导出的常见视频封装。iPhone 是 mov/mp4，安卓多为 mp4，老设备/彩信会有 3gp
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "webm",
        "3gp", "3g2", "mpg", "mpeg", "mts", "m2ts"
    ]

    /// 照片：iPhone 默认 HEIC，安卓多为 JPEG(部分机型 HEIC)，另有 PNG 截图、WebP、GIF、RAW
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "webp", "gif",
        "tif", "tiff", "avif", "heics", "bmp"
    ]

    static func isMediaFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return videoExtensions.contains(ext) || imageExtensions.contains(ext)
    }

    static func discoverMedia(in folder: URL) -> (images: [URL], videos: [URL]) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folder,
                                             includingPropertiesForKeys: [.isRegularFileKey],
                                             // 跳过隐藏文件和 Photos 库之类的包内容，避免把缩略图代理文件也扫进来
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return ([], [])
        }
        var images: [URL] = []
        var videos: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if imageExtensions.contains(ext) {
                images.append(url)
            } else if videoExtensions.contains(ext) {
                videos.append(url)
            }
        }
        return (images, videos)
    }

    /// 与图片同名的短视频 = 实况照片的动态部分（IMG_1234.HEIC + IMG_1234.MOV）
    /// 上限 6 秒：正常视频一般不会这么短，避免把普通短视频误吞
    private static func livePhotoPairs(images: [URL], videos: [URL]) -> Set<String> {
        guard !images.isEmpty, !videos.isEmpty else { return [] }
        let imageNames = Set(images.map { $0.deletingPathExtension().lastPathComponent })
        var paired = Set<String>()
        for v in videos where imageNames.contains(v.deletingPathExtension().lastPathComponent) {
            let av = AVURLAsset(url: v)
            let seconds = CMTimeGetSeconds(av.duration)
            if seconds > 0.2 && seconds < 6 { paired.insert(v.path) }
        }
        return paired
    }

    // MARK: - 建记录

    static func fingerprint(of url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs?[.size] as? Int64 ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)-\(mtime)"
    }

    static func buildAsset(url: URL, fingerprint: String) -> Asset {
        if imageExtensions.contains(url.pathExtension.lowercased()) {
            return buildPhotoAsset(url: url, fingerprint: fingerprint)
        }
        return buildVideoAsset(url: url, fingerprint: fingerprint)
    }

    private static func buildVideoAsset(url: URL, fingerprint: String) -> Asset {
        let avAsset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(avAsset.duration)
        let videoTrack = avAsset.tracks(withMediaType: .video).first
        let size = videoTrack?.naturalSize.applying(videoTrack?.preferredTransform ?? .identity) ?? .zero
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let recordedAt = avAsset.creationDate?.dateValue
            ?? (attrs?[.creationDate] as? Date)
            ?? (attrs?[.modificationDate] as? Date)
        let srtPath = DJINamingRule.srtSibling(for: url)
        var gps = srtPath.flatMap { GPSParser.parseFirstCoordinate(from: $0) }
        if gps == nil { gps = MetadataGPS.from(asset: avAsset) }
        return Asset(
            id: nil,
            filePath: url.path,
            fileName: url.lastPathComponent,
            fileHash: fingerprint,
            fileSize: attrs?[.size] as? Int64 ?? 0,
            durationSeconds: duration.isFinite ? duration : 0,
            width: Int(abs(size.width)),
            height: Int(abs(size.height)),
            frameRate: Double(videoTrack?.nominalFrameRate ?? 0),
            codec: videoTrack.map { "\($0.formatDescriptions.count) track" },
            recordedAt: recordedAt,
            latitude: gps?.0,
            longitude: gps?.1,
            placeName: nil,
            srtPath: srtPath?.path,
            thumbnailPath: nil,
            mediaType: MediaKind.video.rawValue,
            pairedVideoPath: nil,
            rating: 0,
            colorLabel: 0,
            isFavorite: false,
            isDeleted: false,
            createdAt: Date()
        )
    }

    private static func buildPhotoAsset(url: URL, fingerprint: String) -> Asset {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let info = PhotoProbe.info(url: url)
        let recordedAt = info?.recordedAt
            ?? (attrs?[.creationDate] as? Date)
            ?? (attrs?[.modificationDate] as? Date)

        // 动态部分：先找 iPhone 那种同名的 .mov，再看安卓/鸿蒙嵌在图片里的 MP4
        let sibling = Self.liveVideoSibling(for: url)
        let motionPath = sibling?.path ?? MotionPhoto.extract(from: url)?.path
        let hasMotion = motionPath != nil
        let motionSeconds = Self.duration(of: motionPath)

        return Asset(
            id: nil,
            filePath: url.path,
            fileName: url.lastPathComponent,
            fileHash: fingerprint,
            fileSize: attrs?[.size] as? Int64 ?? 0,
            durationSeconds: motionSeconds,
            width: info?.width ?? 0,
            height: info?.height ?? 0,
            frameRate: 0,
            codec: url.pathExtension.uppercased(),
            recordedAt: recordedAt,
            latitude: info?.latitude,
            longitude: info?.longitude,
            placeName: nil,
            srtPath: nil,
            thumbnailPath: nil,
            mediaType: hasMotion ? MediaKind.livePhoto.rawValue : MediaKind.photo.rawValue,
            pairedVideoPath: motionPath,
            rating: 0,
            colorLabel: 0,
            isFavorite: false,
            isDeleted: false,
            createdAt: Date()
        )
    }

    /// 同一目录下同名、且够短的视频 → 认为是这张图的实况部分
    private static func liveVideoSibling(for image: URL) -> URL? {
        let base = image.deletingPathExtension().lastPathComponent
        let dir = image.deletingLastPathComponent()
        for ext in ["mov", "mp4", "m4v"] {
            let candidate = dir.appendingPathComponent("\(base).\(ext)")
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            let seconds = Self.duration(of: candidate)
            if seconds > 0.2 && seconds < 6 { return candidate }
        }
        return nil
    }

    private static func duration(of path: String?) -> Double {
        guard let path else { return 0 }
        return duration(of: URL(fileURLWithPath: path))
    }

    private static func duration(of url: URL?) -> Double {
        guard let url else { return 0 }
        let seconds = CMTimeGetSeconds(AVURLAsset(url: url).duration)
        return seconds.isFinite ? seconds : 0
    }
}
