import Foundation
import GRDB

/// 素材类型。存库用 rawValue，老记录默认 0（视频）
enum MediaKind: Int, Codable, CaseIterable {
    case video = 0
    case photo = 1
    /// 实况照片：静态图 + 一段动态视频（iPhone 的 HEIC+MOV 配对，或安卓/鸿蒙把 MP4 嵌在 JPEG 末尾）
    case livePhoto = 2

    var name: String {
        switch self {
        case .video: return "视频"
        case .photo: return "照片"
        case .livePhoto: return "实况照片"
        }
    }

    var systemImage: String {
        switch self {
        case .video: return "video"
        case .photo: return "photo"
        case .livePhoto: return "livephoto"
        }
    }

    /// 需要走播放器（普通视频、实况的动态部分）
    var isPlayable: Bool { self != .photo }
}

/// 一条素材记录（视频 / 照片 / 实况照片），可关联 SRT / 封面 / 剧照
struct Asset: Codable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var filePath: String
    var fileName: String
    var fileHash: String   // size + mtime 指纹，用于去重
    var fileSize: Int64
    var durationSeconds: Double
    var width: Int
    var height: Int
    var frameRate: Double
    var codec: String?
    var recordedAt: Date?
    var latitude: Double?
    var longitude: Double?
    var placeName: String?
    var srtPath: String?
    var thumbnailPath: String?
    /// MediaKind 的 rawValue
    var mediaType: Int
    /// 实况照片的动态部分：iPhone 是同名的 .mov；安卓/鸿蒙是从 JPEG 末尾提取出来的 .mp4
    var pairedVideoPath: String?
    var rating: Int
    var colorLabel: Int
    var isFavorite: Bool
    var isDeleted: Bool
    var createdAt: Date

    static let databaseTableName = "asset"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Asset {
    var kind: MediaKind { MediaKind(rawValue: mediaType) ?? .video }

    var isVideo: Bool { kind == .video }

    /// 播放器要用的那条路径：视频本身，或实况照片的动态部分
    var playbackPath: String? {
        switch kind {
        case .video: return filePath
        case .livePhoto: return pairedVideoPath ?? filePath
        case .photo: return nil
        }
    }

    var fileExtension: String {
        (filePath as NSString).pathExtension.lowercased()
    }
}

