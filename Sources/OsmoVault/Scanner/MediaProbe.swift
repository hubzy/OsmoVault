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

    /// 提取嵌入的视频。非动态照片返回 nil
    static func extract(from url: URL) -> URL? {
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

        let dest = outputDir.appendingPathComponent("\(fnv1a(url.path)).mp4")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        do {
            try slice.write(to: dest)
            return dest
        } catch {
            return nil
        }
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
