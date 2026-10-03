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

    func requiresReason(from prior: PartStatus) -> Bool {
        guard self != prior else { return false }
        if self == .cancelled || prior == .cancelled { return true }
        let milestones: [PartStatus] = [.needed, .ordered, .arrived, .installed]
        guard let next = milestones.firstIndex(of: self),
            let previous = milestones.firstIndex(of: prior)
        else { return false }
        return next < previous
    }
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
    var status: PartStatus
    var orderedAt: Date?
    var arrivedAt: Date?
    var installedAt: Date?
    var cancelledAt: Date?
    var supplierSnapshot: PartSupplierSnapshot?
    var orderReference: String?
    var statusReason: String?
    let createdAt: Date
    let updatedAt: Date

    static func databaseJSONEncoder(for column: String) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
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

nonisolated struct PartSupplierSnapshot: Codable, Equatable, Sendable {
    let url: String
    let title: String?
    let supplierName: String?
    let supplierStockCode: String?
    let price: String?
    let currency: String?
    let notes: String?

    init(link: PartLink) {
        url = link.url
        title = link.title
        supplierName = link.supplierName
        supplierStockCode = link.supplierStockCode
        price = link.price
        currency = link.currency
        notes = link.notes
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

    static func hasRecordedOrder(_ partID: UUID, for jobID: UUID, in db: Database) throws -> Bool {
        let events = try ActivityEvent.fetchAll(
            db,
            sql: "SELECT * FROM activityEvent WHERE jobID = ? AND kind = ? ORDER BY ordering DESC",
            arguments: [jobID.uuidString, ActivityKind.partStatusChanged.rawValue])
        for event in events {
            guard case .part(let next) = event.nextValue, next.partID == partID else { continue }
            if next.status == .needed { return false }
            if next.status == .ordered || next.orderedAt != nil { return true }
        }
        return false
    }
}
