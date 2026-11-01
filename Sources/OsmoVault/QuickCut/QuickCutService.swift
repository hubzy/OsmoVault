import Foundation
import AVFoundation

/// 一条出片片段：源素材 + 起止时间
struct CutSegment: Identifiable, Codable {
    var id = UUID()
    let assetID: Int64
    let sourcePath: String
    let fileName: String
    var start: Double
    var end: Double
    var duration: Double { max(end - start, 0.1) }
}

/// 出片配置
struct QuickCutConfig {
    enum Aspect: String, CaseIterable, Identifiable {
        case original = "原始", landscape = "16:9", portrait = "9:16", square = "3:4"
        var id: String { rawValue }
        var size: CGSize? {
            switch self {
            case .original: return nil
            case .landscape: return CGSize(width: 1920, height: 1080)
            case .portrait: return CGSize(width: 1080, height: 1920)
            case .square: return CGSize(width: 1080, height: 1440)
            }
        }
    }
    var aspect: Aspect = .original
    var transitionDuration: Double = 0   // 0 = 硬切；>0 = 交叉溶解秒数
    var includeBGM = false
    var bgmPath: String? = nil
}

enum QuickCutService {
    /// 将片段按顺序硬切拼接，导出到目标 URL（mp4）
    static func export(segments: [CutSegment], config: QuickCutConfig, to output: URL,
                       progress: ((Double) -> Void)? = nil) async throws {
        guard !segments.isEmpty else { throw NSError(domain: "QuickCut", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有选择片段"]) }
        var exportAudioMix: AVAudioMix?
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "QuickCut", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建合成轨道"])
        }
        let transition = CMTime(seconds: max(config.transitionDuration, 0), preferredTimescale: 600)
        let useCrossfade = transition > .zero && segments.count > 1
        var cursor = CMTime.zero
        // 交叉溶解：偶数段放轨道 A，奇数段放轨道 B，重叠 transition 时长
        var trackB: AVMutableCompositionTrack?
        if useCrossfade {
            trackB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        for (i, seg) in segments.enumerated() {
            let src = AVURLAsset(url: URL(fileURLWithPath: seg.sourcePath))
            let start = CMTime(seconds: seg.start, preferredTimescale: 600)
            var dur = CMTime(seconds: seg.duration, preferredTimescale: 600)
            let overlap = (useCrossfade && i > 0) ? transition : .zero
            if useCrossfade && i > 0 && i < segments.count - 1 {
                dur = dur - transition  // 中间段两端各让出半个转场，此处简化：重叠占后段开头
            }
            let vTracks = src.tracks(withMediaType: .video)
            guard let v = vTracks.first else { continue }
            let targetTrack = (useCrossfade && i % 2 == 1) ? trackB! : videoTrack
            let insertAt = cursor - overlap
            try targetTrack.insertTimeRange(CMTimeRange(start: start, duration: dur), of: v, at: max(insertAt, .zero))
            if let a = src.tracks(withMediaType: .audio).first {
                try? audioTrack.insertTimeRange(CMTimeRange(start: start, duration: dur), of: a, at: cursor)
            }
            cursor = max(insertAt, .zero) + dur
        }
        guard cursor > .zero else { throw NSError(domain: "QuickCut", code: 3, userInfo: [NSLocalizedDescriptionKey: "拼接后时长为零"]) }

        // BGM：循环铺满全片，原声保留、BGM 音量 0.3
        if config.includeBGM, let bgmPath = config.bgmPath, FileManager.default.fileExists(atPath: bgmPath) {
            let bgm = AVURLAsset(url: URL(fileURLWithPath: bgmPath))
            if let bgmTrack = bgm.tracks(withMediaType: .audio).first,
               let bgmComp = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let totalRange = CMTimeRange(start: .zero, duration: cursor)
                var t = CMTime.zero
                while t < cursor {
                    let remaining = cursor - t
                    let dur = min(bgm.duration, remaining)
                    try? bgmComp.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: bgmTrack, at: t)
                    t = t + dur
                }
                _ = totalRange
                let mix = AVMutableAudioMix()
                let mainParams = AVMutableAudioMixInputParameters(track: audioTrack)
                let bgmParams = AVMutableAudioMixInputParameters(track: bgmComp)
                bgmParams.setVolume(0.3, at: .zero)
                mix.inputParameters = [mainParams, bgmParams]
                exportAudioMix = mix
            }
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "QuickCut", code: 4)
        }
        export.audioMix = exportAudioMix

        // 视频合成：交叉溶解 opacity 动画 + 输出比例
        if useCrossfade, let tb = trackB {
            let vc = AVMutableVideoComposition()
            let natural = composition.naturalSize
            let outSize: CGSize
            if let forced = config.aspect.size {
                // 保持高度按目标比例，宽度取源（等比 letterbox 由 preset 处理；简化取目标尺寸）
                outSize = forced
            } else {
                outSize = CGSize(width: abs(natural.width), height: abs(natural.height))
            }
            vc.renderSize = outSize
            var instructions: [AVMutableVideoCompositionInstruction] = []
            let aParams = AVMutableVideoCompositionLayerInstruction(trackID: videoTrack.trackID)
            let bParams = AVMutableVideoCompositionLayerInstruction(trackID: tb.trackID)
            // 简化方案：A 轨整体 opacity 1；B 轨在各转场窗口内 0→1 渐入。
            // 生成转场时间点列表
            var t = CMTime.zero
            var windows: [CMTimeRange] = []
            for (i, seg) in segments.enumerated() where i > 0 {
                _ = seg
                let src = AVURLAsset(url: URL(fileURLWithPath: segments[i].sourcePath))
                _ = src
                t = CMTime.zero
            }
            // 重建时间线：与插入逻辑一致
            var c = CMTime.zero
            for (i, seg) in segments.enumerated() {
                let dur = CMTime(seconds: seg.duration, preferredTimescale: 600)
                let overlap = (i > 0) ? transition : .zero
                let ins = max(c - overlap, .zero)
                if i > 0 {
                    windows.append(CMTimeRange(start: ins, duration: transition))
                }
                c = ins + dur - ((i > 0 && i < segments.count - 1) ? transition : .zero)
            }
            var fullOpacity = AVMutableVideoCompositionLayerInstruction(trackID: videoTrack.trackID)
            _ = fullOpacity
            fullOpacity = aParams
            for w in windows {
                bParams.setOpacity(0.0, at: w.start)
                bParams.setOpacity(1.0, at: CMTimeRangeGetEnd(w))
            }
            let instr = AVMutableVideoCompositionInstruction()
            instr.timeRange = CMTimeRange(start: .zero, duration: cursor)
            instr.layerInstructions = [fullOpacity, bParams]
            instructions.append(instr)
            vc.instructions = instructions
            vc.frameDuration = CMTime(value: 1, timescale: 30)
            export.videoComposition = vc
        } else if let forced = config.aspect.size {
            let vc = AVMutableVideoComposition()
            vc.renderSize = forced
            vc.frameDuration = CMTime(value: 1, timescale: 30)
            let natural = composition.naturalSize
            if let track = composition.tracks(withMediaType: .video).first {
                let instr = AVMutableVideoCompositionInstruction()
                instr.timeRange = CMTimeRange(start: .zero, duration: cursor)
                let li = AVMutableVideoCompositionLayerInstruction(trackID: track.trackID)
                let scale = min(forced.width / abs(natural.width), forced.height / abs(natural.height))
                li.setTransform(CGAffineTransform(scaleX: scale, y: scale),
                                at: .zero)
                instr.layerInstructions = [li]
                vc.instructions = [instr]
            }
            export.videoComposition = vc
        }

        export.outputURL = output
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        let timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            progress?(Double(export.progress))
        }
        try? FileManager.default.removeItem(at: output)
        await export.export()
        timer.invalidate()
        progress?(1.0)
        if let e = export.error { throw e }
    }

    static func defaultOutputURL() -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let dir = movies.appendingPathComponent("OsmoVault 出片", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmmss"
        return dir.appendingPathComponent("cut_\(fmt.string(from: Date())).mp4")
    }
}

