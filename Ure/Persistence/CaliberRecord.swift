import Foundation
import GRDB

nonisolated enum MovementType: String, Codable, CaseIterable, Identifiable, Sendable {
    case unknown = "Unknown"
    case manual = "Manual"
    case automatic = "Automatic"
    case quartz = "Quartz"
    case other = "Other"

    var id: Self { self }
}

nonisolated struct CaliberRecord: Codable, Equatable, Identifiable, Sendable, FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "caliber"

    let id: UUID
    let designation: String
    let manufacturer: String?
    let variant: String?
    let movementType: MovementType
    let beatRate: Double?
    let jewelCount: Double?
    let powerReserve: Double?
    let liftAngle: Double?
    let specificationNotes: String?
    let sourceNote: String?
    let createdAt: Date
    let updatedAt: Date

    var label: String {
        if let variant { return "\(designation) · \(variant)" }
        return designation
    }

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

nonisolated enum CaliberQueries {
    static func fetchAll(_ db: Database) throws -> [CaliberRecord] {
        try CaliberRecord.fetchAll(
            db, sql: "SELECT * FROM caliber ORDER BY designation COLLATE NOCASE, variant, id")
    }

    static func fetch(_ id: UUID, in db: Database) throws -> CaliberRecord? {
        try CaliberRecord.fetchOne(
            db, sql: "SELECT * FROM caliber WHERE id = ?", arguments: [id.uuidString])
    }

    static func insert(_ record: CaliberRecord, in db: Database) throws {
        try record.insert(db)
        try SearchKey.refresh(record.id, table: .caliber, in: db)
    }

    static func update(_ record: CaliberRecord, in db: Database) throws {
        try record.update(db)
        try SearchKey.refresh(record.id, table: .caliber, in: db)
    }
}
