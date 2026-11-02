import Foundation
import ImageIO
import AVFoundation

/// 从图片文件读出来的基础信息
struct PhotoInfo {
    var width: Int = 0
    var height: Int = 0
    var recordedAt: Date?
    var latitude: Double?
    var longitude: Double?
}

/// 图片的元数据读取。走 ImageIO，HEIC / JPEG / PNG / WebP / AVIF / TIFF 都能读
enum PhotoProbe {
    /// EXIF 里日期的写法是 "2026:01:03 10:45:22"，跟 DateFormatter 常用的格式不一样
    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func info(url: URL) -> PhotoInfo? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }

        var info = PhotoInfo()
        info.width = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        info.height = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0

        // EXIF 记的宽高是传感器原始方向，横躺（orientation 6/8）的图要换过来，
        // 否则竖屏照片在网格和详情页里会被当成横图
        let orientation = (props[kCGImagePropertyTIFFOrientation] as? Int)
            ?? (props[kCGImagePropertyOrientation] as? Int) ?? 1
        if orientation >= 5 && orientation <= 8 {
            swap(&info.width, &info.height)
        }

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        info.recordedAt = date(from: exif?[kCGImagePropertyExifDateTimeOriginal])
            ?? date(from: exif?[kCGImagePropertyExifDateTimeDigitized])
            ?? date(from: tiff?[kCGImagePropertyTIFFDateTime])

        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            let lat = gps[kCGImagePropertyGPSLatitude] as? Double
            let lon = gps[kCGImagePropertyGPSLongitude] as? Double
            let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased()
            let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased()
            if let lat { info.latitude = latRef == "S" ? -lat : lat }
            if let lon { info.longitude = lonRef == "W" ? -lon : lon }
        }
        return info
    }

    private static func date(from value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return exifDateFormatter.date(from: s)
    }
}

/// 安卓 / 鸿蒙的「动态照片」：一段 MP4 直接跟在 JPEG 的结束标记后面（Pixel 的 Motion Photo、
/// 三星 / 小米 / 华为 / OPPO 的实况或动态照片都是这个思路，只是 XMP 标记字段不同）。
/// 这里不依赖厂商标记，直接找文件里最后一个 MP4 box，能解出画面就算数。
enum MotionPhoto {
    private static var outputDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("OsmoVault/motion", isDirectory: true)
    }

    /// 缓存配额：不设上限的话，8000 张实况照片能抽出 30GB 常驻磁盘
    private static let maxCacheBytes: Int = 300 * 1024 * 1024

    // MARK: - 快速探测（扫描阶段）

    /// 各大厂商写在 XMP / 文件尾部的动态照片标记。命中就能确定有嵌入视频，
    /// 不用去翻整个文件。实测华为的照片在**尾部**写 `LIVE_<数字>`（40/40 命中，
    /// 普通照片 0/40 误命中），三星/Pixel/小米则写在头部 XMP 里
    private static let motionMarkers: [[UInt8]] = [
        Array("MotionPhoto".utf8),    // 三星 / Pixel(GCamera)
        Array("motionphoto".utf8),
        Array("HwMotionPhoto".utf8),  // 华为 / 荣耀
        Array("MicroVideo".utf8),     // 小米 / vivo
        Array("LivePhoto".utf8),
        Array("livephoto".utf8),
        Array("LIVE_".utf8)           // 华为写在文件尾部的 trailer
    ]

    /// 只判断"这是不是动态照片"，**不写任何文件**。
    /// 扫描阶段对每张图都跑一次，所以必须便宜：分层读少量字节，绝不全量读盘
    /// （8000 张全量读一遍就是几十 GB I/O，导入会卡到十几分钟）。
    static func containsMotion(in url: URL) -> Bool {
        guard let size = fileSize(of: url), size > 64 * 1024 else { return false }
        // 1) 头部 256KB：三星 / Pixel / 小米这类把标记写在 XMP 里
        if let head = readRange(url: url, offset: 0, length: 256 * 1024),
           containsMarker(in: head) { return true }
        // 2) 尾部 256KB：华为把标记写成文件尾部的 trailer
        if let tail = readRange(url: url, offset: max(0, size - 256 * 1024), length: 256 * 1024),
           containsMarker(in: tail) { return true }
        // 3) 兜底：尾部 1MB 里找 MP4 的 ftyp（动态视频很短的情况）
        if let tail = readRange(url: url, offset: max(0, size - 1024 * 1024), length: 1024 * 1024),
           tail.range(of: Data("ftyp".utf8)) != nil { return true }
        return false
    }

    private static func containsMarker(in data: Data) -> Bool {
        // Data.range(of:) 是精确匹配；厂商标记几种常见写法都列进去了，
        // 不再做小写归一化（避免每次多拷一份 256KB）
        for marker in motionMarkers where data.range(of: Data(marker)) != nil { return true }
        return false
    }

    private static func fileSize(of url: URL) -> Int? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int) ?? (attrs?[.size] as? NSNumber)?.intValue
    }

    /// 读文件的某一段。用 FileHandle 而不是 `Data(contentsOf:)`：
    /// 后者会把整个文件（几十 MB 的照片）映射进内存
    private static func readRange(url: URL, offset: Int, length: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        do {
            if offset > 0 { try handle.seek(toOffset: UInt64(offset)) }
            let data = try handle.read(upToCount: length) ?? Data()
            return data.isEmpty ? nil : data
        } catch { return nil }
    }

    // MARK: - 真正提取（播放时）

    /// 提取嵌入的视频。非动态照片返回 nil。
    /// 只在真正要播放时调用——提取出来的文件会落盘，受 LRU 配额约束
    static func extract(from url: URL) -> URL? {
        let dest = outputDir.appendingPathComponent("\(fnv1a(url.path)).mp4")
        if FileManager.default.fileExists(atPath: dest.path) {
            touch(dest)
            return dest
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 4096 else { return nil }
        guard let start = mp4Start(in: data) else { return nil }

        // box 头 4 字节是大端长度；长度不合法就一直取到文件尾。
        // 这里逐字节拼而不是 load(as: UInt32.self)：切片起点不一定是 4 字节对齐的，
        // 直接 load 会崩（misaligned raw pointer）
        var length = data.count - start
        if start + 4 <= data.count, data.count > start {
            let declared = UInt32(data[start]) << 24
                | UInt32(data[start + 1]) << 16
                | UInt32(data[start + 2]) << 8
                | UInt32(data[start + 3])
            if declared > 4096, start + Int(declared) <= data.count { length = Int(declared) }
        }
        let slice = data[start..<(start + length)]

        // 必须是真能解的视频再落盘，避免普通照片里碰巧出现 ftyp 字样被误判
        let temp = outputDir.appendingPathComponent("probe-\(UUID().uuidString).mp4")
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        do { try slice.write(to: temp) } catch { return nil }
        defer { try? FileManager.default.removeItem(at: temp) }

        let av = AVURLAsset(url: temp)
        guard av.tracks(withMediaType: .video).first != nil,
              CMTimeGetSeconds(av.duration) > 0.1 else { return nil }

        do {
            try slice.write(to: dest)
            trimCache()
            return dest
        } catch {
            return nil
        }
    }

    // MARK: - 配额

    /// 更新访问时间，LRU 淘汰时靠它判断谁最旧。
    /// 一小时内的重复访问不再写属性——`playbackPath` 会在渲染中被反复求值
    private static func touch(_ url: URL) {
        let fm = FileManager.default
        guard let date = try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date,
              Date().timeIntervalSince(date) > 3600 else { return }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// 超过配额就按修改时间从旧到新删。提取出来的动态视频只是缓存，
    /// 删掉不影响素材库，下次播放会重新抽
    static func trimCache(maxBytes: Int = maxCacheBytes) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: outputDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }

        var entries: [(URL, Date, Int)] = []
        var total = 0
        for f in files {
            let values = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let date = values?.contentModificationDate ?? Date.distantPast
            entries.append((f, date, size))
            total += size
        }
        guard total > maxBytes else { return }

        entries.sort { $0.1 < $1.1 }
        for entry in entries {
            guard total > maxBytes else { break }
            try? fm.removeItem(at: entry.0)
            total -= entry.2
        }
    }

    /// 清空全部动态视频缓存（设置里手动触发用）
    static func clearCache() {
        try? FileManager.default.removeItem(at: outputDir)
    }

    /// 找 MP4 的起点：ftyp box 前面 4 字节是它的长度。
    /// 从后往前找——视频永远是追加在 JPEG 末尾的，反向第一次命中就是它
    private static func mp4Start(in data: Data) -> Int? {
        guard let range = data.range(of: Data("ftyp".utf8), options: .backwards),
              range.lowerBound >= 4 else { return nil }
        return range.lowerBound - 4
    }

    private static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return hash
    }
}
