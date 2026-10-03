import Foundation
import GRDB

nonisolated struct TaskPart: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "taskPart"

    let taskID: UUID
    let partID: UUID

    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }
}

nonisolated enum TaskPartAvailability: String, Sendable {
    case waitingForParts = "Waiting for parts"
    case partsAvailable = "Parts available"
    case needsReview = "Needs review"

    static func label(for parts: [PartRecord]) -> Self? {
        guard !parts.isEmpty else { return nil }
        if parts.contains(where: { $0.status == .cancelled }) { return .needsReview }
        if parts.contains(where: { $0.status.isUnresolved }) { return .waitingForParts }
        return .partsAvailable
    }
}

nonisolated struct JobTaskSnapshot: Equatable, Sendable {
    let tasks: [JobTaskRecord]
    let parts: [PartRecord]
    let links: [TaskPart]
}

nonisolated enum TaskPartQueries {
    static func fetchAll(_ db: Database) throws -> [TaskPart] {
        try TaskPart.fetchAll(db, sql: "SELECT * FROM taskPart ORDER BY taskID, partID")
    }

    static func linked(to taskID: UUID, in db: Database) throws -> [TaskPart] {
        try TaskPart.fetchAll(
            db, sql: "SELECT * FROM taskPart WHERE taskID = ? ORDER BY partID",
            arguments: [taskID.uuidString])
    }

    static func snapshot(_ db: Database) throws -> JobTaskSnapshot {
        try JobTaskSnapshot(
            tasks: JobTaskQueries.fetchAll(db),
            parts: PartRecord.fetchAll(
                db, sql: "SELECT * FROM partRequirement ORDER BY createdAt, id"),
            links: fetchAll(db))
    }
}
