import Foundation
import GRDB

nonisolated enum SearchKey {
    static func normalize(_ text: String) -> String {
        text.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    static func make(_ fields: [String?]) -> String {
        normalize(fields.compactMap { $0 }.joined(separator: "\n"))
    }

    static func matches(_ fields: [String?], query: String) -> Bool {
        let key = normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return key.isEmpty || fields.compactMap { $0 }.contains { normalize($0).contains(key) }
    }

    enum Table: String, CaseIterable {
        case watch, caliber, job, libraryItem, partRequirement

        var fields: [String] {
            switch self {
            case .watch:
                [
                    "name", "brand", "model", "caseReference", "serial", "approximateYear", "owner",
                    "contact", "notes",
                ]
            case .caliber: ["designation", "manufacturer", "notes"]
            case .job: ["title", "notes"]
            case .libraryItem: ["title"]
            case .partRequirement: ["description", "manufacturerReference"]
            }
        }
    }

    static func refresh(_ id: UUID, table: Table, in db: Database) throws {
        if let row = try Row.fetchOne(
            db,
            sql:
                "SELECT id, \(table.fields.joined(separator: ", ")) FROM \(table.rawValue) WHERE id = ?",
            arguments: [id.uuidString])
        {
            try refresh(row, table: table.rawValue, fields: table.fields, in: db)
        }
    }

    static func backfill(_ table: Table, in db: Database) throws {
        try backfill(table.rawValue, fields: table.fields, in: db)
    }

    // A migration passes the fields of its own schema, because later schemas change them.
    static func backfill(_ table: String, fields: [String], in db: Database) throws {
        for row in try Row.fetchAll(
            db, sql: "SELECT id, \(fields.joined(separator: ", ")) FROM \(table)")
        {
            try refresh(row, table: table, fields: fields, in: db)
        }
    }

    private static func refresh(
        _ row: Row, table: String, fields: [String], in db: Database
    ) throws {
        let id: String = row["id"]
        let values: [String?] = fields.map { row[$0] }
        try db.execute(
            sql: "UPDATE \(table) SET searchKey = ? WHERE id = ?",
            arguments: [make(values), id])
    }
}
