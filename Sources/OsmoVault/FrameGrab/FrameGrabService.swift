import Foundation
import AVFoundation
import AppKit
import ImageIO

enum FrameGrabService {
    static func grab(asset: Asset, at seconds: Double) throws -> URL {
        let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        let dir = pics.appendingPathComponent("OsmoVault 截图/" + (asset.fileName as NSString).deletingPathExtension, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "HHmmss-SSS"
        let out = dir.appendingPathComponent("IMG_" + fmt.string(from: Date()) + ".jpg")

        let avAsset = AVURLAsset(url: URL(fileURLWithPath: asset.filePath))
        let gen = AVAssetImageGenerator(asset: avAsset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.01, preferredTimescale: 600)
        let cg = try gen.copyCGImage(at: CMTime(seconds: max(seconds, 0), preferredTimescale: 600), actualTime: nil)

        // 写入 EXIF：GPS + 拍摄时间
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw NSError(domain: "FrameGrab", code: 2)
        }
        var props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: ISO8601DateFormatter().string(from: Date())
            ]
        ]
        if let lat = asset.latitude, let lon = asset.longitude {
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(lat),
                kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(lon),
                kCGImagePropertyGPSLongitudeRef: lon >= 0 ? "E" : "W"
            ]
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "FrameGrab", code: 3)
        }
        try (data as Data).write(to: out)
        return out
    }
}

