import Foundation
import GRDB

nonisolated enum PartStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case needed = "Needed"
    case ordered = "Ordered"
    case arrived = "Arrived"
    case installed = "Installed"
    case cancelled = "Cancelled"

    var id: Self { self }
    var isUnresolved: Bool { self == .needed || self == .ordered }
}

nonisolated enum PartCompatibility: String, Codable, CaseIterable, Identifiable, Sendable {
    case unchecked = "Unchecked"
    case confirmed = "Confirmed"
    case unsuitable = "Unsuitable"

    var id: Self { self }
}

nonisolated struct PartRecord: Codable, Equatable, Identifiable, Sendable, FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "partRequirement"

    let id: UUID
    let jobID: UUID
    let description: String
    let quantity: Int
    let manufacturerReference: String?
    let compatibility: PartCompatibility
    let compatibilityNote: String?
    let status: PartStatus
    let createdAt: Date
    let updatedAt: Date

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

nonisolated struct PartLink: Codable, Equatable, Identifiable, Sendable, FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "partLink"

    let id: UUID
    let partID: UUID
    let position: Int
    let url: String
    let title: String?
    let supplierName: String?
    let supplierStockCode: String?
    let price: String?
    let currency: String?
    let notes: String?
    let isSelected: Bool
    let createdAt: Date
    var updatedAt: Date

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

nonisolated struct PartRequirement: Equatable, Identifiable, Sendable {
    let record: PartRecord
    let links: [PartLink]
    var id: UUID { record.id }
    var selectedLink: PartLink? { links.first { $0.isSelected } }
}

nonisolated enum PartQueries {
    static func fetchAll(_ db: Database) throws -> [PartRequirement] {
        let records = try PartRecord.fetchAll(
            db, sql: "SELECT * FROM partRequirement ORDER BY createdAt, id")
        let links = try PartLink.fetchAll(db, sql: "SELECT * FROM partLink ORDER BY position, id")
        let grouped = Dictionary(grouping: links, by: \.partID)
        return records.map { PartRequirement(record: $0, links: grouped[$0.id] ?? []) }
    }

    static func fetch(_ id: UUID, in db: Database) throws -> PartRequirement? {
        guard
            let record = try PartRecord.fetchOne(
                db, sql: "SELECT * FROM partRequirement WHERE id = ?", arguments: [id.uuidString])
        else { return nil }
        let links = try PartLink.fetchAll(
            db, sql: "SELECT * FROM partLink WHERE partID = ? ORDER BY position, id",
            arguments: [id.uuidString])
        return PartRequirement(record: record, links: links)
    }

    static func unresolved(for jobID: UUID, in db: Database) throws -> [PartRecord] {
        try PartRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM partRequirement WHERE jobID = ? AND status IN ('Needed', 'Ordered')
                ORDER BY createdAt, id
                """, arguments: [jobID.uuidString])
    }
}
