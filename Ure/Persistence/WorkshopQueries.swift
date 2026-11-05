import Foundation
import GRDB

nonisolated struct WorkshopJob: Equatable, Identifiable, Sendable {
    let job: JobRecord
    let watch: WatchRecord
    let progress: ChecklistProgress
    let unresolvedPartCount: Int
    let updatedAt: Date

    var id: UUID { job.id }
}

nonisolated enum WorkshopQueries {
    private static let openJobs =
        "SELECT job.id FROM job WHERE \(JobQueries.openStages) AND job.archivedAt IS NULL"

    static func fetch(_ db: Database) throws -> [WorkshopJob] {
        let jobs = try JobRecord.fetchAll(db, sql: "SELECT * FROM job WHERE id IN (\(openJobs))")
        let watches = try WatchRecord.fetchAll(
            db,
            sql:
                "SELECT * FROM watch WHERE id IN (SELECT watchID FROM job WHERE id IN (\(openJobs)))"
        )
        let steps = try ChecklistStepRecord.fetchAll(
            db,
            sql: "SELECT * FROM checklistStep WHERE jobID IN (\(openJobs)) ORDER BY position, id")
        let parts = try PartRecord.fetchAll(
            db, sql: "SELECT * FROM partRequirement WHERE jobID IN (\(openJobs))")
        let watchesByID = Dictionary(uniqueKeysWithValues: watches.map { ($0.id, $0) })
        let stepsByJob = Dictionary(grouping: steps, by: \.jobID)
        let partsByJob = Dictionary(grouping: parts, by: \.jobID)
        return try jobs.map { job in
            guard let watch = watchesByID[job.watchID] else { throw JobError.missingRecord }
            let jobSteps = stepsByJob[job.id] ?? []
            let jobParts = partsByJob[job.id] ?? []
            let updatedAt =
                (jobSteps.map(\.updatedAt) + jobParts.map(\.updatedAt) + [job.updatedAt])
                .max() ?? job.updatedAt
            return WorkshopJob(
                job: job, watch: watch, progress: ChecklistProgress(records: jobSteps),
                unresolvedPartCount: jobParts.filter { $0.status.isUnresolved }.count,
                updatedAt: updatedAt)
        }.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
