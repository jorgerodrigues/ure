import Foundation
import GRDB

nonisolated enum JobTimelineError: LocalizedError {
    case invalidEvent

    var errorDescription: String? {
        "A saved activity entry could not be read. The saved history has been kept."
    }
}

nonisolated enum JobTimelineQueries {
    static func fetch(_ jobID: UUID, in db: Database) throws -> [JobTimelineEntry] {
        guard let job = try JobQueries.fetch(jobID, in: db) else { throw JobError.missingRecord }
        let events = try ActivityEvent.fetchAll(
            db, sql: "SELECT * FROM activityEvent WHERE jobID = ? ORDER BY ordering",
            arguments: [jobID.uuidString])
        let notes = try NoteRecord.fetchAll(
            db, sql: "SELECT * FROM note WHERE jobID = ?", arguments: [jobID.uuidString])
        let taskIDs = Set(try JobTaskQueries.ordered(for: jobID, in: db).map(\.id))
        let partIDs = Set(
            try PartRecord.fetchAll(
                db, sql: "SELECT * FROM partRequirement WHERE jobID = ?",
                arguments: [jobID.uuidString]
            ).map(\.id))
        let entries =
            try events.map {
                try JobTimelineEntry(
                    event: $0, watchID: job.watchID, taskIDs: taskIDs, partIDs: partIDs)
            } + notes.map(JobTimelineEntry.init)
        return entries.sorted(by: JobTimelineEntry.newestFirst)
    }
}
