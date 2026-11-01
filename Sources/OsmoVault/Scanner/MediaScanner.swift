import Foundation
import AVFoundation
import GRDB

struct MediaScanner {
    let database: AppDatabase

    func scan(folder: URL) -> AsyncStream<ScanProgress> {
        AsyncStream { continuation in
            let task = Task {
                var newCount = 0
                var dupCount = 0
                continuation.yield(ScanProgress(state: .discovering, currentFile: nil))

                let videoURLs = Self.discoverVideoFiles(in: folder)
                let total = videoURLs.count

                for (index, url) in videoURLs.enumerated() {
                    try Task.checkCancellation()
                    let fp = Self.fingerprint(of: url)
                    let isDup = (try? database.hasAny(filePath: url.path, fingerprint: fp)) ?? false
                    if isDup {
                        dupCount += 1
                    } else {
                        var asset = Self.buildAsset(url: url, fingerprint: fp, srtPath: DJINamingRule.srtSibling(for: url))
                        try? database.save(&asset)
                        newCount += 1
                    }
                    continuation.yield(ScanProgress(state: .importing(indexed: index + 1, total: total), currentFile: url.lastPathComponent))
                }
                continuation.yield(ScanProgress(state: .finished(newAssets: newCount, duplicates: dupCount), currentFile: nil))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func discoverVideoFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            if videoExtensions.contains(url.pathExtension.lowercased()) { result.append(url) }
        }
        return result
    }

    static let videoExtensions = ["mp4", "mov"]

    static func fingerprint(of url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs?[.size] as? Int64 ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)-\(mtime)"
    }

    static func buildAsset(url: URL, fingerprint: String, srtPath: URL?) -> Asset {
        let avAsset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(avAsset.duration)
        let videoTrack = avAsset.tracks(withMediaType: .video).first
        let size = videoTrack?.naturalSize.applying(videoTrack?.preferredTransform ?? .identity) ?? .zero
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let recordedAt = avAsset.creationDate?.dateValue
            ?? (attrs?[.creationDate] as? Date)
            ?? (attrs?[.modificationDate] as? Date)
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
            rating: 0,
            colorLabel: 0,
            isFavorite: false,
            isDeleted: false,
            createdAt: Date()
        )
    }
}

