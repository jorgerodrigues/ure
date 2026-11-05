import Foundation
import GRDB

// How a movement is wound. A caliber whose winding nobody has written down has none.
nonisolated enum Winding: String, Codable, CaseIterable, Identifiable, Sendable {
    case manual = "Manual"
    case automatic = "Automatic"
    case quartz = "Quartz"

    var id: Self { self }

    // A winding written in full or by its first letters, such as "auto", in any case.
    init?(written text: String) {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty,
            let match = Self.allCases.first(where: { winding in
                winding.rawValue.range(of: typed, options: [.anchored, .caseInsensitive]) != nil
            })
        else { return nil }
        self = match
    }
}

nonisolated struct CaliberRecord: Codable, Equatable, Identifiable, Sendable, FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "caliber"

    let id: UUID
    var designation: String
    var manufacturer: String?
    var winding: Winding?
    var beatRate: Double?
    var jewelCount: Double?
    var powerReserve: Double?
    var liftAngle: Double?
    let createdAt: Date
    var updatedAt: Date
    var archivedAt: Date? = nil

    // The caliber's maker and name, such as "Omega 552".
    var title: String {
        guard let manufacturer, !manufacturer.isEmpty else { return designation }
        return "\(manufacturer) \(designation)"
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
            db, sql: "SELECT * FROM caliber ORDER BY designation COLLATE NOCASE, id")
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
