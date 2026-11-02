import Foundation
import GRDB

final class AppDatabase {
    let dbWriter: DatabaseWriter

    init(dbWriter: DatabaseWriter) {
        self.dbWriter = dbWriter
        try? migrator.migrate(dbWriter)
    }

    static func open() throws -> AppDatabase {
        let fm = FileManager.default
        let folder = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("OsmoVault", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: folder.appendingPathComponent("vault.sqlite").path)
        return AppDatabase(dbWriter: pool)
    }

    static func inMemory() -> AppDatabase {
        AppDatabase(dbWriter: try! DatabaseQueue())
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "asset") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("filePath", .text).notNull().unique()
                t.column("fileName", .text).notNull()
                t.column("fileHash", .text).notNull().indexed()
                t.column("fileSize", .integer).notNull()
                t.column("durationSeconds", .double).notNull().defaults(to: 0)
                t.column("width", .integer).notNull().defaults(to: 0)
                t.column("height", .integer).notNull().defaults(to: 0)
                t.column("frameRate", .double).notNull().defaults(to: 0)
                t.column("codec", .text)
                t.column("recordedAt", .datetime).indexed()
                t.column("latitude", .double)
                t.column("longitude", .double)
                t.column("placeName", .text)
                t.column("srtPath", .text)
                t.column("thumbnailPath", .text)
                t.column("rating", .integer).notNull().defaults(to: 0)
                t.column("colorLabel", .integer).notNull().defaults(to: 0)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v2") { db in
            try db.alter(table: "asset") { t in
                t.add(column: "isDeleted", .boolean).notNull().defaults(to: false)
            }
        }
        // 支持照片 / 实况照片：老记录默认 0（视频），pairedVideoPath 为空
        migrator.registerMigration("v3") { db in
            try db.alter(table: "asset") { t in
                t.add(column: "mediaType", .integer).notNull().defaults(to: 0)
                t.add(column: "pairedVideoPath", .text)
            }
        }
        return migrator
    }

    var dbReader: DatabaseReader { dbWriter }

    func readAssets() throws -> [Asset] {
        try dbReader.read { db in
            try Asset.filter(Column("isDeleted") == false)
                .order(Column("recordedAt").desc).fetchAll(db)
        }
    }

    func readDeletedAssets() throws -> [Asset] {
        try dbReader.read { db in
            try Asset.filter(Column("isDeleted") == true)
                .order(Column("recordedAt").desc).fetchAll(db)
        }
    }

    func setDeleted(id: Int64, deleted: Bool) throws {
        try dbWriter.write { db in
            try db.execute(sql: "UPDATE asset SET isDeleted = ? WHERE id = ?", arguments: [deleted, id])
        }
    }

    func save(_ asset: inout Asset) throws {
        try dbWriter.write { db in
            try asset.save(db)
        }
    }

    /// 批量写入（一个事务）。扫描 8000 条素材时逐条 `save` 就是 8000 次事务 + fsync，
    /// 这是导入卡住的主要原因之一。`didInsert` 仍会回填 id。
    func saveBatch(_ assets: inout [Asset]) throws {
        guard !assets.isEmpty else { return }
        try dbWriter.write { db in
            for i in assets.indices {
                try assets[i].save(db)
            }
        }
    }

    /// 一次把去重需要的索引读进内存。扫描时对每个文件发两次 SQL（8000 × 2 次查询）
    /// 换成扫开始前的一次全表投影 + 内存 Set 判断
    func existingIndex() -> (paths: Set<String>, hashes: Set<String>) {
        (try? dbReader.read { db in
            var paths = Set<String>()
            var hashes = Set<String>()
            var rows = try Row.fetchAll(db, sql: "SELECT filePath, fileHash FROM asset")
            paths.reserveCapacity(rows.count)
            hashes.reserveCapacity(rows.count)
            for row in rows {
                paths.insert(row["filePath"])
                hashes.insert(row["fileHash"])
            }
            return (paths, hashes)
        }) ?? ([], [])
    }

    func updateRating(id: Int64, rating: Int) throws {
        try dbWriter.write { db in
            try db.execute(sql: "UPDATE asset SET rating = ? WHERE id = ?", arguments: [rating, id])
        }
    }

    func updateColorLabel(id: Int64, label: Int) throws {
        try dbWriter.write { db in
            try db.execute(sql: "UPDATE asset SET colorLabel = ? WHERE id = ?", arguments: [label, id])
        }
    }

    func setFavorite(id: Int64, favorite: Bool) throws {
        try dbWriter.write { db in
            try db.execute(sql: "UPDATE asset SET isFavorite = ? WHERE id = ?", arguments: [favorite, id])
        }
    }

    func setPlaceName(id: Int64, name: String) throws {
        try dbWriter.write { db in
            try db.execute(sql: "UPDATE asset SET placeName = ? WHERE id = ?", arguments: [name, id])
        }
    }

    /// 彻底删除索引记录（不动磁盘文件）。用于移除误导入的重复来源
    func delete(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try dbWriter.write { db in
            let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
            try db.execute(sql: "DELETE FROM asset WHERE id IN (\(marks))",
                           arguments: StatementArguments(ids))
        }
    }

    func hasAny(filePath: String, fingerprint: String) throws -> Bool {
        try dbReader.read { db in
            let byPath = try Row.fetchOne(db, sql: "SELECT 1 FROM asset WHERE filePath = ?", arguments: [filePath]) != nil
            if byPath { return true }
            return try Row.fetchOne(db, sql: "SELECT 1 FROM asset WHERE fileHash = ?", arguments: [fingerprint]) != nil
        }
    }
}

