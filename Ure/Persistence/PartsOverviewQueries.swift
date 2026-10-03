import Foundation
import GRDB

nonisolated struct OverviewPart: Equatable, Identifiable, Sendable {
    let part: PartRecord
    let job: JobRecord
    let watch: WatchRecord
    let searchKey: String

    var id: UUID { part.id }
}

nonisolated enum PartsOverviewQueries {
    private static let openJobs =
        """
        SELECT job.id FROM job JOIN watch ON watch.id = job.watchID
        WHERE job.stage IN ('Planned', 'In progress', 'Waiting', 'Ready')
          AND job.archivedAt IS NULL AND watch.archivedAt IS NULL
        """

    static func fetch(_ db: Database) throws -> [OverviewPart] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT p.*, p.searchKey || char(10) || coalesce(links.keys, '') AS combinedSearchKey
                FROM partRequirement p
                LEFT JOIN (
                    SELECT partID, group_concat(searchKey, char(10)) AS keys
                    FROM partLink GROUP BY partID
                ) links ON links.partID = p.id
                WHERE jobID IN (\(openJobs))
                ORDER BY p.updatedAt DESC, p.id
                """)
        let jobs = try JobRecord.fetchAll(db, sql: "SELECT * FROM job WHERE id IN (\(openJobs))")
        let watches = try WatchRecord.fetchAll(
            db,
            sql:
                "SELECT * FROM watch WHERE id IN (SELECT watchID FROM job WHERE id IN (\(openJobs)))"
        )
        let jobsByID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        let watchesByID = Dictionary(uniqueKeysWithValues: watches.map { ($0.id, $0) })
        return try rows.map { row in
            let part = try PartRecord(row: row)
            guard let job = jobsByID[part.jobID], let watch = watchesByID[job.watchID] else {
                throw PartError.missingRecord
            }
            return OverviewPart(
                part: part, job: job, watch: watch, searchKey: row["combinedSearchKey"])
        }
    }
}
