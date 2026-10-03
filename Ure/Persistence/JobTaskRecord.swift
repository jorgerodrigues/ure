import Foundation
import GRDB

nonisolated enum JobTaskStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case toDo = "To do"
    case doing = "Doing"
    case waiting = "Waiting"
    case done = "Done"
    case skipped = "Skipped"

    var id: Self { self }
    var isUnfinished: Bool { self != .done && self != .skipped }
}

nonisolated struct JobTaskRecord: Codable, Equatable, Identifiable, Sendable, FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "jobTask"

    let id: UUID
    let jobID: UUID
    let title: String
    let detail: String?
    let groupLabel: String?
    let status: JobTaskStatus
    let waitingReason: String?
    let skippedReason: String?
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

nonisolated enum JobTaskQueries {
    static func fetchAll(_ db: Database) throws -> [JobTaskRecord] {
        try JobTaskRecord.fetchAll(db, sql: "SELECT * FROM jobTask ORDER BY createdAt, id")
    }

    static func fetch(_ id: UUID, in db: Database) throws -> JobTaskRecord? {
        try JobTaskRecord.fetchOne(
            db, sql: "SELECT * FROM jobTask WHERE id = ?", arguments: [id.uuidString])
    }

    static func unfinished(for jobID: UUID, in db: Database) throws -> [JobTaskRecord] {
        try JobTaskRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM jobTask WHERE jobID = ? AND status IN ('To do', 'Doing', 'Waiting')
                ORDER BY createdAt, id
                """, arguments: [jobID.uuidString])
    }
}
