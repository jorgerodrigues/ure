import Foundation
import GRDB

nonisolated enum JobStage: String, Codable, Sendable {
    case planned = "Planned"
    case inProgress = "In progress"
    case waiting = "Waiting"
    case ready = "Ready"
    case completed = "Completed"
    case cancelled = "Cancelled"

    var isOpen: Bool { self != .completed && self != .cancelled }
}

nonisolated struct JobIntakeSnapshot: Codable, Equatable, Sendable {
    let version: Int
    let watchName: String
    let brand: String?
    let model: String?
    let caseReference: String?
    let serial: String?
    let caliberDesignation: String?
    let caliberVariant: String?

    init(watch: WatchRecord, caliber: CaliberRecord?) {
        version = 1
        watchName = watch.name
        brand = watch.brand
        model = watch.model
        caseReference = watch.caseReference
        serial = watch.serial
        caliberDesignation = caliber?.designation
        caliberVariant = caliber?.variant
    }

    init(
        watchName: String, brand: String?, model: String?, caseReference: String?, serial: String?,
        caliberDesignation: String?, caliberVariant: String?
    ) {
        version = 1
        self.watchName = watchName
        self.brand = brand
        self.model = model
        self.caseReference = caseReference
        self.serial = serial
        self.caliberDesignation = caliberDesignation
        self.caliberVariant = caliberVariant
    }
}

nonisolated struct JobRecord: Codable, Equatable, Identifiable, Sendable, FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "job"

    let id: UUID
    let watchID: UUID
    let title: String
    let stage: JobStage
    let reportedProblem: String?
    let agreedScope: String?
    let intakeCondition: String?
    let ownerName: String?
    let ownerEmail: String?
    let ownerPhone: String?
    let intakeSnapshot: JobIntakeSnapshot
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

nonisolated enum JobQueries {
    static func fetchAll(_ db: Database) throws -> [JobRecord] {
        try JobRecord.fetchAll(db, sql: "SELECT * FROM job ORDER BY createdAt DESC, id")
    }

    static func fetch(_ id: UUID, in db: Database) throws -> JobRecord? {
        try JobRecord.fetchOne(
            db, sql: "SELECT * FROM job WHERE id = ?", arguments: [id.uuidString])
    }

    static func openJob(for watchID: UUID, in db: Database) throws -> JobRecord? {
        try JobRecord.fetchOne(
            db,
            sql: """
                SELECT * FROM job WHERE watchID = ?
                AND stage IN ('Planned', 'In progress', 'Waiting', 'Ready')
                """, arguments: [watchID.uuidString])
    }

    static func insert(_ record: JobRecord, in db: Database) throws { try record.insert(db) }
    static func update(_ record: JobRecord, in db: Database) throws { try record.update(db) }
}
