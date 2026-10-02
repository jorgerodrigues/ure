import Foundation
import GRDB

nonisolated enum WatchCondition: String, Codable, CaseIterable, Sendable {
    case unknown = "Unknown"
    case running = "Running"
    case runningPoorly = "Running poorly"
    case stopped = "Stopped"
    case disassembled = "Disassembled"
}

nonisolated struct WatchRecord: Codable, Equatable, Identifiable, Sendable, FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "watch"

    let id: UUID
    let name: String
    let brand: String?
    let model: String?
    let caseReference: String?
    let serial: String?
    let approximateYear: String?
    let caliberID: UUID?
    let caseMaterial: String?
    let caseDiameter: Double?
    let lugWidth: Double?
    let waterResistance: String?
    let specificationNotes: String?
    let createdAt: Date
    var updatedAt: Date
    var condition: WatchCondition = .unknown
    var conditionNote: String? = nil
    var coverPhotoID: UUID? = nil

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
    }

    static func update(_ record: WatchRecord, in db: Database) throws {
        try record.update(db)
    }
}
