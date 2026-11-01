import Foundation

/// 解析 DJI SRT 中的 GPS 坐标
enum GPSParser {
    static func parseFirstCoordinate(from srtURL: URL) -> (Double, Double)? {
        guard let text = try? String(contentsOf: srtURL, encoding: .utf8) else { return nil }
        return parseFirstCoordinate(fromText: text)
    }

    /// 兼容两种 DJI SRT 常见格式：
    ///   [latitude:31.230400] [longitude:121.473700]
    ///   GPS(121.473700,31.230400,120)
    static func parseFirstCoordinate(fromText text: String) -> (Double, Double)? {
        if let (lat, lon) = firstGroupPair(in: text, pattern: "latitude:(-?[0-9.]+)\\]\\s*\\[longitude:(-?[0-9.]+)") {
            return (lat, lon)
        }
        if let (lon, lat) = firstGroupPair(in: text, pattern: "GPS\\(([0-9.]+),([0-9.]+)") {
            return (lat, lon)
        }
        return nil
    }

    static func firstGroupPair(in text: String, pattern: String) -> (Double, Double)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range), m.numberOfRanges >= 3,
              let r1 = Range(m.range(at: 1), in: text), let r2 = Range(m.range(at: 2), in: text),
              let v1 = Double(text[r1]), let v2 = Double(text[r2]) else { return nil }
        return (v1, v2)
    }
}

/// 从 MP4 元数据读 GPS（ISO6709 位置字符串）
import AVFoundation
enum MetadataGPS {
    static func from(asset: AVURLAsset) -> (Double, Double)? {
        let item = asset.commonMetadata.first { meta in
            meta.identifier?.rawValue.lowercased().contains("location.iso6709") == true
        }
        guard let value = item?.stringValue else { return nil }
        return ISO6709.parse(value)
    }
}

enum ISO6709 {
    /// 如 "+31.2304+121.4737/"
    static func parse(_ s: String) -> (Double, Double)? {
        guard let regex = try? NSRegularExpression(pattern: "([+-][0-9.]+)([+-][0-9.]+)") else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = regex.firstMatch(in: s, range: range), m.numberOfRanges >= 3,
              let r1 = Range(m.range(at: 1), in: s), let r2 = Range(m.range(at: 2), in: s),
              let lat = Double(s[r1]), let lon = Double(s[r2]) else { return nil }
        return (lat, lon)
    }
}

