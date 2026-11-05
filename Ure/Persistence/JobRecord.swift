import Foundation
import GRDB

// A job is In progress or Waiting while the watch is on the bench, and Done when the work is
// finished. A Done job stays editable. A watch has at most one job that is not Done.
nonisolated enum JobStage: String, Codable, CaseIterable, Sendable {
    case inProgress = "In progress"
    case waiting = "Waiting"
    case done = "Done"

    var isOpen: Bool { self != .done }
}

nonisolated struct JobRecord: Codable, Equatable, Identifiable, Sendable, FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "job"

    let id: UUID
    let watchID: UUID
    var title: String
    var stage: JobStage
    var problem: String? = nil
    // What a waiting job waits for, such as "a mainspring". Only a waiting job has one.
    var waitingFor: String? = nil
    // When the job was opened. The page reads it as "Opened 12 October".
    let createdAt: Date
    var updatedAt: Date
    // When the job was set to Done. Only a done job has one.
    var doneAt: Date? = nil
    var archivedAt: Date? = nil

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

nonisolated enum JobQueries {
    // The jobs that are not Done. A watch has at most one.
    static let openStages = "stage IN ('In progress', 'Waiting')"

    static func fetchAll(_ db: Database) throws -> [JobRecord] {
        try JobRecord.fetchAll(db, sql: "SELECT * FROM job ORDER BY createdAt DESC, id")
    }

    static func fetch(_ id: UUID, in db: Database) throws -> JobRecord? {
        try JobRecord.fetchOne(
            db, sql: "SELECT * FROM job WHERE id = ?", arguments: [id.uuidString])
    }

    static func openJob(for watchID: UUID, in db: Database) throws -> JobRecord? {
        try JobRecord.fetchOne(
            db, sql: "SELECT * FROM job WHERE watchID = ? AND \(openStages)",
            arguments: [watchID.uuidString])
    }

    static func insert(_ record: JobRecord, in db: Database) throws {
        try record.insert(db)
        try SearchKey.refresh(record.id, table: .job, in: db)
    }

    static func update(_ record: JobRecord, in db: Database) throws {
        try record.update(db)
        try SearchKey.refresh(record.id, table: .job, in: db)
    }
}
