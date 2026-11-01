import Foundation

/// 识别 DJI/Osmo 命名规则：DJI_0123.MP4 / DJI_0123.SRT 等
enum DJINamingRule {
    static let srtExtensions = ["srt"]

    static func clipID(of fileName: String) -> String? {
        let base = (fileName as NSString).deletingPathExtension
        guard base.uppercased().hasPrefix("DJI_") else { return nil }
        let suffix = base.dropFirst(4)
        return suffix.isEmpty ? nil : String(suffix)
    }

    static func srtSibling(for videoURL: URL) -> URL? {
        let dir = videoURL.deletingLastPathComponent()
        let base = (videoURL.lastPathComponent as NSString).deletingPathExtension
        for ext in srtExtensions {
            let candidate = dir.appendingPathComponent(base + "." + ext)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

