import Foundation
import AVFoundation
import CoreMedia

/// 一条出片片段：源素材 + 起止时间 + 变速倍率
struct CutSegment: Identifiable, Codable, Equatable {
    var id = UUID()
    let assetID: Int64
    let sourcePath: String
    let fileName: String
    var start: Double
    var end: Double
    /// 变速 0.25x–4x（音频随速变调，导出管线暂不做原调保持）
    var speed: Double = 1
    /// 该片段在**时间轴上**占用的秒数（源时长 ÷ 变速）
    var duration: Double { max((end - start) / min(max(speed, 0.25), 4), 0.1) }
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

enum QuickCutError: LocalizedError {
    case empty
    case noVideoTrack
    case zeroLength
    case noExportSession
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .empty: return "还没有任何片段"
        case .noVideoTrack: return "选中的素材里没有可用的视频轨"
        case .zeroLength: return "拼接后时长为零"
        case .noExportSession: return "无法创建导出会话"
        case .exportFailed(let msg): return "导出失败：\(msg)"
        }
    }
}

/// 一条构建好的时间线。`export` 与预览播放器共用同一份，保证「预览即所得」
struct PreparedTimeline {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVAudioMix?
    let total: CMTime
    let renderSize: CGSize
    /// 每段在时间轴上的起点（已含转场重叠偏移），预览跳段用
    let segmentStarts: [CMTime]

    /// 预览画面的宽高比：横屏宽撑满，竖屏按高撑满
    var renderRatio: CGFloat {
        let w = max(renderSize.width, 1), h = max(renderSize.height, 1)
        return w / h
    }
}

enum QuickCutService {
    private struct Source {
        let asset: AVURLAsset
        let videoTrack: AVAssetTrack
        let audioTrack: AVAssetTrack?
        let mediaRange: CMTimeRange
    }

    /// 将片段按顺序拼成时间线（导出、预览共用，保证两边效果一致）。
    /// 变速片段：按源区间插入后用 `scaleTimeRange` 压缩到目标时长（音画同步缩放）。
    static func prepare(segments: [CutSegment], config: QuickCutConfig) throws -> PreparedTimeline {
        guard !segments.isEmpty else { throw QuickCutError.empty }

        // 1. 解析源素材，并把用户填的起止时间夹到真实时长范围内
        var sources: [Source] = []
        var speeds: [Double] = []
        for seg in segments {
            let av = AVURLAsset(url: URL(fileURLWithPath: seg.sourcePath))
            guard let v = av.tracks(withMediaType: .video).first else { continue }
            let totalSeconds = CMTimeGetSeconds(av.duration)
            let maxDur = totalSeconds.isFinite && totalSeconds > 0 ? totalSeconds : seg.end
            let start = min(max(seg.start, 0), max(maxDur - 0.2, 0))
            let end = min(max(seg.end, start + 0.2), maxDur)
            let range = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: max(end - start, 0.2), preferredTimescale: 600)
            )
            sources.append(Source(asset: av, videoTrack: v,
                                  audioTrack: av.tracks(withMediaType: .audio).first,
                                  mediaRange: range))
            speeds.append(min(max(seg.speed, 0.25), 4))
        }
        guard !sources.isEmpty else { throw QuickCutError.noVideoTrack }

        // 每段在时间轴上的时长（源时长 ÷ 变速）
        let timelineDurations: [CMTime] = sources.indices.map { i in
            CMTimeMultiplyByFloat64(sources[i].mediaRange.duration, multiplier: 1 / speeds[i])
        }

        // 2. 编排时间轴：转场时长不能超过最短片段的 45%，否则会算出负长度的时间区间
        var transition = CMTime(seconds: max(config.transitionDuration, 0), preferredTimescale: 600)
        let crossfade = transition > .zero && sources.count > 1
        if crossfade {
            let shortest = timelineDurations.min() ?? .zero
            transition = CMTimeMinimum(transition, CMTimeMultiplyByFloat64(shortest, multiplier: 0.45))
        } else {
            transition = .zero
        }
        let useCrossfade = crossfade && transition > .zero

        var positions: [CMTime] = []
        var cursor = CMTime.zero
        for (i, s) in sources.enumerated() {
            if i > 0 { cursor = cursor - transition }
            positions.append(cursor)
            cursor = cursor + timelineDurations[i]
        }
        let total = cursor
        guard total > .zero else { throw QuickCutError.zeroLength }

        // 3. 每个片段独占一条视频轨，交叉溶解时相邻片段才有重叠的余地
        let composition = AVMutableComposition()
        var videoTracks: [AVMutableCompositionTrack] = []
        var audioTracks: [AVMutableCompositionTrack] = []

        for (i, s) in sources.enumerated() {
            guard let vt = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw QuickCutError.noExportSession
            }
            vt.preferredTransform = s.videoTrack.preferredTransform
            try vt.insertTimeRange(s.mediaRange, of: s.videoTrack, at: positions[i])
            videoTracks.append(vt)

            if let a = s.audioTrack,
               let at = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? at.insertTimeRange(s.mediaRange, of: a, at: positions[i])
                audioTracks.append(at)
                // 变速：把刚插入的音画同步压缩到 timelineDurations[i]
                if speeds[i] != 1 {
                    let inserted = CMTimeRange(start: positions[i], duration: s.mediaRange.duration)
                    try? vt.scaleTimeRange(inserted, toDuration: timelineDurations[i])
                    try? at.scaleTimeRange(inserted, toDuration: timelineDurations[i])
                }
            } else if speeds[i] != 1 {
                let inserted = CMTimeRange(start: positions[i], duration: s.mediaRange.duration)
                try? vt.scaleTimeRange(inserted, toDuration: timelineDurations[i])
            }
        }

        // 4. 画幅：强制比例用目标尺寸，否则用第一段素材的实际尺寸
        let renderSize = config.aspect.size ?? orientedSize(of: sources[0].videoTrack)
        let fps = max(sources.map { $0.videoTrack.nominalFrameRate }.max() ?? 30, 24)

        let vc = AVMutableVideoComposition()
        vc.renderSize = renderSize
        vc.frameDuration = CMTime(value: 1, timescale: Int32(max(fps.rounded(), 24)))
        vc.renderScale = 1.0

        let layerInstructions: [AVMutableVideoCompositionLayerInstruction] = sources.indices.map { i in
            let li = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTracks[i])
            li.setTransform(fitTransform(track: sources[i].videoTrack, renderSize: renderSize), at: .zero)
            li.setOpacity(1.0, at: .zero)
            return li
        }

        var instructions: [AVMutableVideoCompositionInstruction] = []
        for i in sources.indices {
            let p = positions[i]
            let d = timelineDurations[i]
            // 该片段独占的区间（不含前后转场）
            let soloStart = i == 0 ? CMTime.zero : p + transition
            let soloEnd = i == sources.count - 1 ? p + d : p + d - transition
            if soloEnd > soloStart {
                let instr = AVMutableVideoCompositionInstruction()
                instr.timeRange = CMTimeRange(start: soloStart, duration: soloEnd - soloStart)
                instr.layerInstructions = [layerInstructions[i]]
                instructions.append(instr)
            }
            // 与下一段之间的交叉溶解窗口
            if useCrossfade, i + 1 < sources.count {
                let window = CMTimeRange(start: positions[i + 1], duration: transition)
                // 前段淡出 + 后段淡入：两条都做斜坡，无论图层顺序如何都能看出转场
                layerInstructions[i].setOpacityRamp(fromStartOpacity: 1.0, toEndOpacity: 0.0, timeRange: window)
                layerInstructions[i + 1].setOpacityRamp(fromStartOpacity: 0.0, toEndOpacity: 1.0, timeRange: window)
                let instr = AVMutableVideoCompositionInstruction()
                instr.timeRange = window
                instr.layerInstructions = [layerInstructions[i], layerInstructions[i + 1]]
                instructions.append(instr)
            }
        }
        vc.instructions = instructions

        // 5. BGM：循环铺满全片，原声保留、BGM 音量 0.3
        var exportAudioMix: AVAudioMix?
        if config.includeBGM, let bgmPath = config.bgmPath, FileManager.default.fileExists(atPath: bgmPath),
           let bgmTrack = AVURLAsset(url: URL(fileURLWithPath: bgmPath)).tracks(withMediaType: .audio).first,
           let bgmComp = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let bgmSeconds = CMTimeGetSeconds(bgmTrack.asset?.duration ?? .zero)
            if bgmSeconds.isFinite && bgmSeconds > 0.5 {
                var t = CMTime.zero
                while t < total {
                    let piece = min(CMTime(seconds: bgmSeconds, preferredTimescale: 600), total - t)
                    if piece <= .zero { break }
                    try? bgmComp.insertTimeRange(CMTimeRange(start: .zero, duration: piece), of: bgmTrack, at: t)
                    t = t + piece
                }
                let mix = AVMutableAudioMix()
                let bgmParams = AVMutableAudioMixInputParameters(track: bgmComp)
                bgmParams.setVolume(0.3, at: .zero)
                mix.inputParameters = audioTracks.map { AVMutableAudioMixInputParameters(track: $0) } + [bgmParams]
                exportAudioMix = mix
            }
        }

        return PreparedTimeline(composition: composition,
                                videoComposition: vc,
                                audioMix: exportAudioMix,
                                total: total,
                                renderSize: renderSize,
                                segmentStarts: positions)
    }

    /// 把拼好的时间线导出到目标 URL（mp4）
    static func export(segments: [CutSegment], config: QuickCutConfig, to output: URL,
                       progress: ((Double) -> Void)? = nil) async throws {
        guard !segments.isEmpty else { throw QuickCutError.empty }
        let timeline = try prepare(segments: segments, config: config)

        guard let export = AVAssetExportSession(asset: timeline.composition,
                                                presetName: AVAssetExportPresetHighestQuality) else {
            throw QuickCutError.noExportSession
        }
        export.outputURL = output
        export.outputFileType = .mp4
        export.videoComposition = timeline.videoComposition
        export.audioMix = timeline.audioMix
        export.shouldOptimizeForNetworkUse = true
        export.canPerformMultiplePassesOverSourceMediaData = true

        try? FileManager.default.removeItem(at: output)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            progress?(Double(export.progress))
        }
        await export.export()
        timer.invalidate()
        progress?(1.0)

        if export.status == .failed || export.status == .cancelled {
            throw QuickCutError.exportFailed(export.error?.localizedDescription ?? "未知错误")
        }
    }

    static func defaultOutputURL() -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let dir = movies.appendingPathComponent("OsmoVault 出片", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmmss"
        return dir.appendingPathComponent("cut_\(fmt.string(from: Date())).mp4")
    }

    // MARK: - 几何

    private static func orientedSize(of track: AVAssetTrack) -> CGSize {
        let s = track.naturalSize.applying(track.preferredTransform)
        return CGSize(width: max(abs(s.width), 16), height: max(abs(s.height), 16))
    }

    /// 把源画面转正后等比铺满目标画幅，多余部分裁掉（cover）
    private static func fitTransform(track: AVAssetTrack, renderSize: CGSize) -> CGAffineTransform {
        let oriented = track.naturalSize.applying(track.preferredTransform)
        let w = max(abs(oriented.width), 1)
        let h = max(abs(oriented.height), 1)
        let scale = max(renderSize.width / w, renderSize.height / h)
        let tx = (renderSize.width - w * scale) / 2
        let ty = (renderSize.height - h * scale) / 2

        var t = track.preferredTransform
        // 旋转后画面原点可能落在负坐标，先移回原点
        t = t.concatenating(CGAffineTransform(translationX: -min(oriented.width, 0), y: -min(oriented.height, 0)))
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        t = t.concatenating(CGAffineTransform(translationX: tx, y: ty))
        return t
    }
}
