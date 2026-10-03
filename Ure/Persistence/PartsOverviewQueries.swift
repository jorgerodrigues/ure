import Foundation
import GRDB

nonisolated struct OverviewPart: Equatable, Identifiable, Sendable {
    let part: PartRecord
    let job: JobRecord
    let watch: WatchRecord

    var id: UUID { part.id }
}

nonisolated enum PartsOverviewQueries {
    private static let openJobs =
        "SELECT id FROM job WHERE stage IN ('Planned', 'In progress', 'Waiting', 'Ready')"

    static func fetch(_ db: Database) throws -> [OverviewPart] {
        let parts = try PartRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM partRequirement WHERE jobID IN (\(openJobs))
                ORDER BY updatedAt DESC, id
                """)
        let jobs = try JobRecord.fetchAll(db, sql: "SELECT * FROM job WHERE id IN (\(openJobs))")
        let watches = try WatchRecord.fetchAll(
            db,
            sql:
                "SELECT * FROM watch WHERE id IN (SELECT watchID FROM job WHERE id IN (\(openJobs)))"
        )
        let jobsByID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        let watchesByID = Dictionary(uniqueKeysWithValues: watches.map { ($0.id, $0) })
        return try parts.map { part in
            guard let job = jobsByID[part.jobID], let watch = watchesByID[job.watchID] else {
                throw PartError.missingRecord
            }
            return OverviewPart(part: part, job: job, watch: watch)
        }
    }
}
