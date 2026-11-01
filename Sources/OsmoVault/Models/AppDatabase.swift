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

