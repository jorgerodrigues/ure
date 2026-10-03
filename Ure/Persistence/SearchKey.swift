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
        case watch, caliber, job, note, libraryItem, partRequirement, partLink

        var fields: [String] {
            switch self {
            case .watch: ["name", "brand", "model", "caseReference", "serial", "approximateYear"]
            case .caliber: ["designation", "manufacturer", "variant"]
            case .job: ["title"]
            case .note: ["title", "body"]
            case .libraryItem: ["title", "caption"]
            case .partRequirement: ["description", "manufacturerReference", "supplierStockCode"]
            case .partLink: ["supplierStockCode"]
            }
        }

        var projection: String {
            if self == .partRequirement {
                return
                    "description, manufacturerReference, json_extract(supplierSnapshot, '$.supplierStockCode') AS supplierStockCode"
            }
            return fields.joined(separator: ", ")
        }
    }

    static func refresh(_ id: UUID, table: Table, in db: Database) throws {
        if let row = try Row.fetchOne(
            db, sql: "SELECT id, \(table.projection) FROM \(table.rawValue) WHERE id = ?",
            arguments: [id.uuidString])
        {
            try refresh(row, table: table, in: db)
        }
    }

    static func backfill(_ table: Table, in db: Database) throws {
        for row in try Row.fetchAll(
            db, sql: "SELECT id, \(table.projection) FROM \(table.rawValue)")
        {
            try refresh(row, table: table, in: db)
        }
    }

    private static func refresh(_ row: Row, table: Table, in db: Database) throws {
        let id: String = row["id"]
        let fields: [String?] = table.fields.map { row[$0] }
        try db.execute(
            sql: "UPDATE \(table.rawValue) SET searchKey = ? WHERE id = ?",
            arguments: [make(fields), id])
    }
}
