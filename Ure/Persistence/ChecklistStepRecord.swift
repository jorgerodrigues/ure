import Foundation
import GRDB

// One line of a job's checklist: a step with a tick, or a heading such as "Cleaning". Steps are
// in the order they were typed, and a heading has no tick.
nonisolated struct ChecklistStepRecord: Codable, Equatable, Identifiable, Sendable,
    FetchableRecord, PersistableRecord
{
    static let databaseTableName = "checklistStep"

    let id: UUID
    let jobID: UUID
    var position: Int
    var text: String
    var isHeading: Bool
    var isTicked: Bool
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

nonisolated enum ChecklistQueries {
    static func fetchAll(_ db: Database) throws -> [ChecklistStepRecord] {
        try ChecklistStepRecord.fetchAll(
            db, sql: "SELECT * FROM checklistStep ORDER BY jobID, position, id")
    }

    static func ordered(for jobID: UUID, in db: Database) throws -> [ChecklistStepRecord] {
        try ChecklistStepRecord.fetchAll(
            db, sql: "SELECT * FROM checklistStep WHERE jobID = ? ORDER BY position, id",
            arguments: [jobID.uuidString])
    }
}
