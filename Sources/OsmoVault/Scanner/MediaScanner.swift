import Foundation
import AVFoundation
import GRDB

struct MediaScanner {
    let database: AppDatabase

    /// 一批并发探测多少个文件。太大内存涨，太小跑不满 SSD 的并发 I/O
    private static let probeChunk = 16

    func scan(folder: URL) -> AsyncStream<ScanProgress> {
        AsyncStream { continuation in
            // 必须 detached：用 Task 会继承调用方的 MainActor，整个扫描（读几千个文件的
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
                let files = (media.images + media.videos)
                    .filter { !pairedVideos.contains($0.path) }
                    .sorted { $0.path < $1.path }
                let total = files.count

                // 去重索引一次读进内存：每个文件发两条 SQL 的话，8000 个文件就是 16000 次查询
                var index = database.existingIndex()
                var done = 0

                for offset in stride(from: 0, to: files.count, by: Self.probeChunk) {
                    try Task.checkCancellation()
                    let chunk = Array(files[offset..<min(offset + Self.probeChunk, files.count)])

                    // 并发探测元数据。串行 await 每个 AVAsset 的话，几千个文件的等待时间
                    // 是累加的，这一处基本决定了导入要跑多久
                    var built: [Asset] = []
                    built.reserveCapacity(chunk.count)
                    await withTaskGroup(of: Asset?.self) { group in
                        for url in chunk {
                            group.addTask { await Self.buildAsset(url: url) }
                        }
                        for await asset in group {
                            if let asset { built.append(asset) }
                        }
                    }

                    var pending: [Asset] = []
                    pending.reserveCapacity(built.count)
                    for asset in built {
                        if index.paths.contains(asset.filePath) || index.hashes.contains(asset.fileHash) {
                            dupCount += 1
                            continue
                        }
                        index.paths.insert(asset.filePath)
                        index.hashes.insert(asset.fileHash)
                        pending.append(asset)
                    }

                    // 一个事务写一批。逐条 INSERT 等于每条一次 fsync
                    try? database.saveBatch(&pending)
                    for a in pending where a.id != nil { newIDs.append(a.id!) }
                    newCount += pending.count

                    done += chunk.count
                    continuation.yield(ScanProgress(state: .importing(indexed: done, total: total),
                                                    currentFile: chunk.last?.lastPathComponent))
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

    /// 异步版：`AVAsset.duration` / `tracks(...)` 都是同步阻塞属性，
    /// 一个个读会把整批文件的等待时间累加起来
    static func buildAsset(url: URL) async -> Asset? {
        let fp = fingerprint(of: url)
        if imageExtensions.contains(url.pathExtension.lowercased()) {
            return buildPhotoAsset(url: url, fingerprint: fp)
        }
        return await buildVideoAsset(url: url, fingerprint: fp)
    }

    private static func buildVideoAsset(url: URL, fingerprint: String) async -> Asset? {
        let avAsset = AVURLAsset(url: url)
        guard let duration = try? await avAsset.load(.duration) else { return nil }
        let seconds = duration.isNumeric ? CMTimeGetSeconds(duration) : 0
        guard let tracks = try? await avAsset.loadTracks(withMediaType: .video),
              let track = tracks.first else { return nil }

        async let sizeValue = track.load(.naturalSize)
        async let transformValue = track.load(.preferredTransform)
        async let fpsValue = track.load(.nominalFrameRate)
        async let formatsValue = track.load(.formatDescriptions)
        let size = (try? await sizeValue)?.applying((try? await transformValue) ?? .identity) ?? .zero
        let fps = (try? await fpsValue) ?? 0
        let formats = (try? await formatsValue) ?? []

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let srtPath = DJINamingRule.srtSibling(for: url)
        var gps = srtPath.flatMap { GPSParser.parseFirstCoordinate(from: $0) }
        if gps == nil, let common = try? await avAsset.load(.commonMetadata) {
            gps = gpsFrom(common)
        }
        let recordedAt = (try? await avAsset.load(.creationDate))?.dateValue
            ?? (attrs?[.creationDate] as? Date)
            ?? (attrs?[.modificationDate] as? Date)

        var asset = Asset(
            id: nil,
            filePath: url.path,
            fileName: url.lastPathComponent,
            fileHash: fingerprint,
            fileSize: attrs?[.size] as? Int64 ?? 0,
            durationSeconds: seconds.isFinite ? seconds : 0,
            width: Int(abs(size.width)),
            height: Int(abs(size.height)),
            frameRate: Double(fps),
            codec: formats.first.flatMap { fourCC(CMFormatDescriptionGetMediaSubType($0)) }
                ?? url.pathExtension.uppercased(),
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
        SidecarService.read(for: url, fileHash: fingerprint).map { ann in
            // 伴生文件里的标注覆盖原生 EXIF / SRT：xmp（人工）优先
            if ann.locationCleared {
                asset.latitude = nil
                asset.longitude = nil
                asset.placeName = nil
            } else if let lat = ann.latitude, let lon = ann.longitude {
                asset.latitude = lat
                asset.longitude = lon
                if let p = ann.placeName { asset.placeName = p }
            } else if let p = ann.placeName, asset.placeName == nil {
                asset.placeName = p
            }
            if let r = ann.rating { asset.rating = r }
            if let c = ann.colorLabel { asset.colorLabel = c }
            if let f = ann.isFavorite { asset.isFavorite = f }
        }
        return asset
    }

    private static func buildPhotoAsset(url: URL, fingerprint: String) -> Asset {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let info = PhotoProbe.info(url: url)
        let recordedAt = info?.recordedAt
            ?? (attrs?[.creationDate] as? Date)
            ?? (attrs?[.modificationDate] as? Date)

        // 动态部分：先找 iPhone 那种同名的 .mov，再看安卓/鸿蒙嵌在图片里的 MP4。
        // 注意这里**只探测不抽取** —— 8000 张照片每张抽一份视频落盘就是 30GB
        let sibling = Self.liveVideoSibling(for: url)
        let hasMotion = sibling != nil || MotionPhoto.containsMotion(in: url)

        var asset = Asset(
            id: nil,
            filePath: url.path,
            fileName: url.lastPathComponent,
            fileHash: fingerprint,
            fileSize: attrs?[.size] as? Int64 ?? 0,
            durationSeconds: 0,
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
            pairedVideoPath: sibling?.path,
            rating: 0,
            colorLabel: 0,
            isFavorite: false,
            isDeleted: false,
            createdAt: Date()
        )
        SidecarService.read(for: url, fileHash: fingerprint).map { ann in
            if ann.locationCleared {
                asset.latitude = nil
                asset.longitude = nil
                asset.placeName = nil
            } else if let lat = ann.latitude, let lon = ann.longitude {
                asset.latitude = lat
                asset.longitude = lon
                if let p = ann.placeName { asset.placeName = p }
            } else if let p = ann.placeName, asset.placeName == nil {
                asset.placeName = p
            }
            if let r = ann.rating { asset.rating = r }
            if let c = ann.colorLabel { asset.colorLabel = c }
            if let f = ann.isFavorite { asset.isFavorite = f }
        }
        return asset
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

    private static func duration(of url: URL?) -> Double {
        guard let url else { return 0 }
        let seconds = CMTimeGetSeconds(AVURLAsset(url: url).duration)
        return seconds.isFinite ? seconds : 0
    }

    private static func gpsFrom(_ metadata: [AVMetadataItem]) -> (Double, Double)? {
        guard let item = metadata.first(where: {
            $0.identifier?.rawValue.lowercased().contains("location.iso6709") == true
        }), let value = item.stringValue else { return nil }
        return ISO6709.parse(value)
    }

    /// FourCharCode 转字符串。MP4 的 codec 存的是 'avc1' / 'hvc1' 这类四字符码
    private static func fourCC(_ code: FourCharCode) -> String? {
        guard code != 0 else { return nil }
        var chars: [Character] = []
        for shift in [24, 16, 8, 0] {
            let byte = UInt8((code >> UInt32(shift)) & 0xff)
            if byte >= 32, byte < 127 { chars.append(Character(UnicodeScalar(byte))) }
        }
        let s = String(chars).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }
}
