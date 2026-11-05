import Foundation
import GRDB

// One row of the Jobs list: the job, its watch when it has one, how many of its checklist steps
// are ticked, and how many of its parts are still to buy.
nonisolated struct JobListRow: Equatable, Identifiable, Sendable {
    let job: JobRecord
    let watch: WatchRecord?
    let progress: ChecklistProgress
    let partsToBuy: Int
    // The last change to the job, its steps or its parts. Open jobs list the newest first.
    let updatedAt: Date

    var id: UUID { job.id }
}

nonisolated enum JobListQueries {
    // Every job that is not archived and is either open or done since the cutoff.
    static func fetch(_ db: Database, doneSince cutoff: Date) throws -> [JobListRow] {
        let listed = """
            SELECT id FROM job WHERE archivedAt IS NULL
                AND (\(JobQueries.openStages) OR doneAt >= ?)
            """
        let arguments: StatementArguments = [cutoff.timeIntervalSince1970]
        let jobs = try JobRecord.fetchAll(
            db, sql: "SELECT * FROM job WHERE id IN (\(listed))", arguments: arguments)
        let watches = try WatchRecord.fetchAll(
            db,
            sql:
                "SELECT * FROM watch WHERE id IN (SELECT watchID FROM job WHERE id IN (\(listed)))",
            arguments: arguments)
        let steps = try ChecklistStepRecord.fetchAll(
            db,
            sql: "SELECT * FROM checklistStep WHERE jobID IN (\(listed)) ORDER BY position, id",
            arguments: arguments)
        let parts = try PartRecord.fetchAll(
            db, sql: "SELECT * FROM part WHERE jobID IN (\(listed))",
            arguments: arguments)
        let watchesByID = Dictionary(uniqueKeysWithValues: watches.map { ($0.id, $0) })
        let stepsByJob = Dictionary(grouping: steps, by: \.jobID)
        let partsByJob = Dictionary(grouping: parts) { $0.jobID }
        return jobs.map { job in
            let jobSteps = stepsByJob[job.id] ?? []
            let jobParts = partsByJob[job.id] ?? []
            let updatedAt =
                (jobSteps.map(\.updatedAt) + jobParts.map(\.updatedAt) + [job.updatedAt]).max()
                ?? job.updatedAt
            return JobListRow(
                job: job, watch: job.watchID.flatMap { watchesByID[$0] },
                progress: ChecklistProgress(records: jobSteps),
                partsToBuy: jobParts.filter { $0.stage == .needed }.count, updatedAt: updatedAt)
        }
    }
}
