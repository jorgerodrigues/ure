import Foundation
import GRDB

// One row of the Parts list: the part, its job and the job's watch, or neither for a spare.
nonisolated struct PartListRow: Equatable, Identifiable, Sendable {
    let part: PartRecord
    let job: JobRecord?
    let watch: WatchRecord?

    var id: UUID { part.id }
}

nonisolated enum PartListQueries {
    // The parts on their way: still to buy, ordered or in hand. Each is on a job that is open
    // and not archived, or in the drawer as a spare. The newest change comes first.
    static func fetch(_ db: Database) throws -> [PartListRow] {
        let openJobs = "SELECT id FROM job WHERE \(JobQueries.openStages) AND archivedAt IS NULL"
        let parts = try PartRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM part
                WHERE stage != 'Fitted' AND (jobID IS NULL OR jobID IN (\(openJobs)))
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
        return parts.map { part in
            let job = part.jobID.flatMap { jobsByID[$0] }
            return PartListRow(
                part: part, job: job, watch: job?.watchID.flatMap { watchesByID[$0] })
        }
    }
}
