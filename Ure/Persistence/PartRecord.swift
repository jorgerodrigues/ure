import Foundation
import GRDB

// Where a part is on its way to the watch. A click on a part's state moves it on: Needed,
// Ordered, In hand, then Fitted, the last. Each state after Needed records the day it came.
nonisolated enum PartStage: String, Codable, CaseIterable, Identifiable, Sendable {
    case needed = "Needed"
    case ordered = "Ordered"
    case inHand = "In hand"
    case fitted = "Fitted"

    var id: Self { self }

    // The state a click moves the part to, or nil once it is fitted.
    var next: PartStage? {
        switch self {
        case .needed: .ordered
        case .ordered: .inHand
        case .inHand: .fitted
        case .fitted: nil
        }
    }

    // Whether the part has come this far, such as an In hand part that was ordered.
    func hasReached(_ milestone: PartStage) -> Bool {
        let order = Self.allCases
        return (order.firstIndex(of: self) ?? 0) >= (order.firstIndex(of: milestone) ?? 0)
    }
}

// A part is a record of its own. It belongs to a job, or it is a spare in the drawer when it has
// no job. Each part has a name, a free-text description, a quantity, a state with the dates it
// was ordered, came in hand and was fitted, and notes.
nonisolated struct PartRecord: Codable, Equatable, Identifiable, Sendable, FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "part"

    let id: UUID
    // The job the part is for, or nil for a spare.
    var jobID: UUID?
    // The part's place among its job's parts.
    var position: Int
    var name: String
    var description: String? = nil
    var quantity: Int = 1
    var stage: PartStage = .needed
    var orderedAt: Date? = nil
    var inHandAt: Date? = nil
    var fittedAt: Date? = nil
    var notes = ""
    let createdAt: Date
    var updatedAt: Date

    var isSpare: Bool { jobID == nil }

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

// A saved link on a part, such as a listing or an identification reference. It holds only its
// URL. W041 turns links into buying options.
nonisolated struct PartLink: Codable, Equatable, Identifiable, Sendable, FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "partLink"

    let id: UUID
    let partID: UUID
    let position: Int
    let url: String
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

// Every part and every saved link, as the parts state observes them.
nonisolated struct PartLibrary: Equatable, Sendable {
    var parts: [PartRecord] = []
    var links: [UUID: [PartLink]] = [:]
}

nonisolated enum PartQueries {
    static func fetchAll(_ db: Database) throws -> [PartRecord] {
        try PartRecord.fetchAll(db, sql: "SELECT * FROM part ORDER BY position, createdAt, id")
    }

    static func library(_ db: Database) throws -> PartLibrary {
        let links = try PartLink.fetchAll(db, sql: "SELECT * FROM partLink ORDER BY position, id")
        return PartLibrary(
            parts: try fetchAll(db), links: Dictionary(grouping: links, by: \.partID))
    }

    static func fetch(_ id: UUID, in db: Database) throws -> PartRecord? {
        try PartRecord.fetchOne(
            db, sql: "SELECT * FROM part WHERE id = ?", arguments: [id.uuidString])
    }

    static func links(of id: UUID, in db: Database) throws -> [PartLink] {
        try PartLink.fetchAll(
            db, sql: "SELECT * FROM partLink WHERE partID = ? ORDER BY position, id",
            arguments: [id.uuidString])
    }

    // The place after the job's last part.
    static func nextPosition(on jobID: UUID, in db: Database) throws -> Int {
        try Int.fetchOne(
            db, sql: "SELECT coalesce(max(position) + 1, 0) FROM part WHERE jobID = ?",
            arguments: [jobID.uuidString]) ?? 0
    }

    static func insert(_ record: PartRecord, in db: Database) throws {
        try record.insert(db)
        try SearchKey.refresh(record.id, table: .part, in: db)
    }

    static func update(_ record: PartRecord, in db: Database) throws {
        try record.update(db)
        try SearchKey.refresh(record.id, table: .part, in: db)
    }
}
