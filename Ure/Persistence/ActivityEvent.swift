import Foundation
import GRDB

nonisolated enum ActivityKind: String, Codable, Sendable {
    case jobStageChanged = "Job stage changed"
    case watchConditionChanged = "Watch condition changed"
}

nonisolated struct JobStageValue: Codable, Equatable, Sendable {
    let stage: JobStage
    let waitingReason: String?
    let outcome: String?
    let recommendations: String?
    let cancellationReason: String?
    let startedAt: Date?
    let completedAt: Date?
    let cancelledAt: Date?

    init(job: JobRecord) {
        stage = job.stage
        waitingReason = job.waitingReason
        outcome = job.outcome
        recommendations = job.recommendations
        cancellationReason = job.cancellationReason
        startedAt = job.startedAt
        completedAt = job.completedAt
        cancelledAt = job.cancelledAt
    }
}

nonisolated struct WatchConditionValue: Codable, Equatable, Sendable {
    let condition: WatchCondition
    let note: String?

    init(watch: WatchRecord) {
        condition = watch.condition
        note = watch.conditionNote
    }
}

nonisolated enum ActivityValue: Codable, Equatable, Sendable {
    case job(JobStageValue)
    case condition(WatchConditionValue)
}

nonisolated struct ActivityEvent: Codable, Equatable, Identifiable, Sendable, FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "activityEvent"

    let id: UUID
    let jobID: UUID
    let kind: ActivityKind
    let occurredAt: Date
    let ordering: Int64
    let priorValue: ActivityValue
    let nextValue: ActivityValue

    static func databaseJSONEncoder(for column: String) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    static func databaseJSONDecoder(for column: String) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
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

nonisolated enum ActivityQueries {
    static func fetchAll(_ db: Database) throws -> [ActivityEvent] {
        try ActivityEvent.fetchAll(db, sql: "SELECT * FROM activityEvent ORDER BY ordering")
    }

    static func insert(
        jobID: UUID, kind: ActivityKind, prior: ActivityValue, next: ActivityValue,
        in db: Database, dependencies: LibraryDependencies
    ) throws {
        let ordering =
            try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(ordering), 0) + 1 FROM activityEvent")
            ?? 1
        try ActivityEvent(
            id: dependencies.makeID(), jobID: jobID, kind: kind,
            occurredAt: Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970),
            ordering: ordering, priorValue: prior, nextValue: next
        ).insert(db)
    }
}
