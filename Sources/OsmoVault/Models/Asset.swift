import Foundation
import GRDB

/// 一条视频素材记录（可关联 SRT / 封面 / 剧照）
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

