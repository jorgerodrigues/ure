import Foundation
import GRDB

nonisolated struct BackupSummary: Equatable, Sendable {
    let date: Date
    let counts: [String: Int]
    let originalCount: Int
    let estimatedByteCount: Int64

    var itemCount: Int {
        ["watch", "caliber", "job", "jobTask", "partRequirement", "note", "libraryItem"]
            .reduce(0) { $0 + (counts[$1] ?? 0) }
    }
}

nonisolated struct BackupManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let formatVersion: Int
    let exportedAt: Date
    let libraryID: UUID
    let applicationVersion: String
    let migrations: [String]
    let counts: [String: Int]
    let files: [SnapshotFile]

    var byteCount: Int64 { files.reduce(0) { $0 + $1.byteCount } }
}

nonisolated enum BackupProgress: Equatable, Sendable {
    case database
    case originals(completed: Int, total: Int)
    case validating
    case publishing
}

nonisolated enum BackupCheckpoint: Sendable {
    case copiedDatabase
    case copiedChunk
    case beforeValidation(URL)
    case beforePublish
}

nonisolated enum BackupQueries {
    static func counts(_ db: Database) throws -> [String: Int] {
        let tables = try String.fetchAll(
            db,
            sql: """
                SELECT name FROM sqlite_schema
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'
                ORDER BY name
                """)
        var counts: [String: Int] = [:]
        for table in tables {
            let quoted = table.replacingOccurrences(of: "\"", with: "\"\"")
            counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(quoted)\"")
        }
        return counts
    }

    static func summary(_ db: Database, date: Date) throws -> BackupSummary {
        let assets = try FileAssetQueries.fetchAll(db)
        let pages = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
        let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
        return BackupSummary(
            date: date, counts: try counts(db), originalCount: assets.count,
            estimatedByteCount: pages * pageSize + assets.reduce(0) { $0 + $1.byteCount })
    }
}
