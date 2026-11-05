import Foundation
import GRDB

// A watch on the bench: what it is, its caliber, its case, and who owns it. The owner and the
// contact are plain text, because Ure never sends messages.
nonisolated struct WatchRecord: Codable, Equatable, Identifiable, Sendable, FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "watch"

    let id: UUID
    var name: String
    var brand: String?
    var model: String?
    var caseReference: String?
    var serial: String?
    var approximateYear: String?
    var caliberID: UUID?
    var caseMaterial: String?
    var caseDiameter: Double?
    var lugWidth: Double?
    var owner: String? = nil
    var contact: String? = nil
    let createdAt: Date
    var updatedAt: Date
    var coverPhotoID: UUID? = nil

    var archivedAt: Date? = nil

    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }

    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }

    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
}

nonisolated enum WatchQueries {
    static func fetchAll(_ db: Database) throws -> [WatchRecord] {
        try WatchRecord.fetchAll(db, sql: "SELECT * FROM watch ORDER BY name COLLATE NOCASE, id")
    }

    static func fetch(_ id: UUID, in db: Database) throws -> WatchRecord? {
        try WatchRecord.fetchOne(
            db, sql: "SELECT * FROM watch WHERE id = ?", arguments: [id.uuidString])
    }

    static func insert(_ record: WatchRecord, in db: Database) throws {
        try record.insert(db)
        try SearchKey.refresh(record.id, table: .watch, in: db)
    }

    static func update(_ record: WatchRecord, in db: Database) throws {
        try record.update(db)
        try SearchKey.refresh(record.id, table: .watch, in: db)
    }
}
