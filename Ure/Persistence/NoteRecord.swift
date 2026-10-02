import Foundation
import GRDB

nonisolated enum NoteKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case observation = "Observation"
    case research = "Research"
    case workLog = "Work log"
    case measurement = "Measurement"

    var id: Self { self }
}

nonisolated enum NoteOwner: Equatable, Sendable {
    case watch(UUID)
    case job(UUID)
    case caliber(UUID)

    var scope: String {
        switch self {
        case .watch: "Watch"
        case .job: "Job"
        case .caliber: "Caliber"
        }
    }
}

nonisolated struct NoteRecord: Codable, Equatable, Identifiable, Sendable, FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "note"

    let id: UUID
    let watchID: UUID?
    let jobID: UUID?
    let caliberID: UUID?
    let title: String
    let body: String
    let kind: NoteKind
    let occurredAt: Date
    let createdAt: Date
    let updatedAt: Date

    func belongs(to owner: NoteOwner) -> Bool {
        switch owner {
        case .watch(let id): watchID == id
        case .job(let id): jobID == id
        case .caliber(let id): caliberID == id
        }
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

nonisolated enum NoteQueries {
    static func fetchAll(_ db: Database) throws -> [NoteRecord] {
        try NoteRecord.fetchAll(db, sql: "SELECT * FROM note ORDER BY occurredAt DESC, id")
    }

    static func fetch(_ id: UUID, in db: Database) throws -> NoteRecord? {
        try NoteRecord.fetchOne(
            db, sql: "SELECT * FROM note WHERE id = ?", arguments: [id.uuidString])
    }

    static func insert(_ record: NoteRecord, in db: Database) throws { try record.insert(db) }
    static func update(_ record: NoteRecord, in db: Database) throws { try record.update(db) }
}
