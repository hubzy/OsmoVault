import Foundation
import AVFoundation
import AppKit
import ImageIO

enum FrameGrabService {
    /// 截「实况图」：一张静帧（照片部分）+ 一段围绕该时刻的短视频（动态部分）。
    /// 二者同名（`IMG_xxx.jpg` + `IMG_xxx.mp4`），与 iPhone 实况照片的配对规则一致，
    /// 导入后会以「实况照片」形式出现，悬停即可播放那段动态。
    static func grabLivePhoto(asset: Asset, at seconds: Double) throws -> (photoURL: URL, videoURL: URL) {
        let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        let dir = pics.appendingPathComponent("OsmoVault 截图/" + (asset.fileName as NSString).deletingPathExtension, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "HHmmss-SSS"
        let stem = "IMG_" + fmt.string(from: Date())

        let photoURL = dir.appendingPathComponent(stem + ".jpg")
        let videoURL = dir.appendingPathComponent(stem + ".mp4")

        // 照片部分：当前帧
        try writeFrame(to: photoURL, asset: asset, at: seconds)
        // 动态部分：围绕当前时刻截一段短视频
        try writeClip(to: videoURL, source: URL(fileURLWithPath: asset.filePath), at: seconds)

        return (photoURL, videoURL)
    }

    // MARK: - 静帧

    private static func writeFrame(to out: URL, asset: Asset, at seconds: Double) throws {
        let avAsset = AVURLAsset(url: URL(fileURLWithPath: asset.filePath))
        let gen = AVAssetImageGenerator(asset: avAsset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.01, preferredTimescale: 600)
        let cg = try gen.copyCGImage(at: CMTime(seconds: max(seconds, 0), preferredTimescale: 600), actualTime: nil)

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw NSError(domain: "FrameGrab", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建图片"])
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
            throw NSError(domain: "FrameGrab", code: 3, userInfo: [NSLocalizedDescriptionKey: "写入图片失败"])
        }
        try (data as Data).write(to: out)
    }

    // MARK: - 动态片段

    private static func writeClip(to out: URL, source: URL, at seconds: Double) throws {
        let asset = AVURLAsset(url: source)
        let total = CMTimeGetSeconds(asset.duration)
        guard total.isFinite, total > 0 else {
            throw NSError(domain: "FrameGrab", code: 5, userInfo: [NSLocalizedDescriptionKey: "无法读取视频时长"])
        }
        // 实况动态通常 1.5~3 秒：取围绕当前时刻的一段，最长 3 秒
        let clip = min(3.0, total)
        let start = max(0, min(seconds - clip / 2, total - clip))
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                duration: CMTime(seconds: clip, preferredTimescale: 600))

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else {
            throw NSError(domain: "FrameGrab", code: 6, userInfo: [NSLocalizedDescriptionKey: "无法创建导出会话"])
        }
        session.timeRange = range
        session.outputURL = out
        session.outputFileType = .mp4
        // 处理旋转：让导出的短视频方向和原片一致（竖屏不会被压成横屏）
        if let track = asset.tracks(withMediaType: .video).first {
            let t = track.preferredTransform
            let transformed = track.naturalSize.applying(t)
            let comp = AVMutableVideoComposition()
            comp.frameDuration = CMTime(value: 1, timescale: 30)
            comp.renderSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
            let instr = AVMutableVideoCompositionInstruction()
            instr.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(t, at: .zero)
            instr.layerInstructions = [layer]
            comp.instructions = [instr]
            session.videoComposition = comp
        }
        try? FileManager.default.removeItem(at: out)
        var done = false
        let sem = DispatchSemaphore(value: 0)
        session.exportAsynchronously { done = true; sem.signal() }
        sem.wait()
        guard session.status == .completed else {
            throw session.error ?? NSError(domain: "FrameGrab", code: 7, userInfo: [NSLocalizedDescriptionKey: "导出短视频失败"])
        }
        _ = done
    }
}
