import Foundation
import GRDB

// Before v24, a job's checklist was a list of tasks. Each task had a title, an optional detail
// and group label, one of five statuses, a waiting or skipped reason, and links to the job's
// parts. A checklist is now a list of steps you type: text with a tick, or a heading. Each task
// becomes a step with the same ID in the same order. Done and Skipped tasks are ticked. A group
// label becomes a heading where the group changes. The details and reasons go into the job's
// notes with the step text, so nothing typed is lost.
nonisolated enum ChecklistMigration {
    static func convertTasks(in db: Database) throws {
        let tasks = try Row.fetchAll(
            db,
            sql: """
                SELECT jobTask.id, jobTask.jobID, jobTask.title, jobTask.detail,
                    jobTask.groupLabel, jobTask.status, jobTask.waitingReason,
                    jobTask.skippedReason, jobTask.createdAt, jobTask.updatedAt
                FROM jobTask JOIN job ON job.id = jobTask.jobID
                ORDER BY job.createdAt, job.id, jobTask.position, jobTask.id
                """)
        var jobs: [String] = []
        var steps: [String: [Step]] = [:]
        var entries: [String: [String]] = [:]
        // The group of each job's task before, which a task without a group ends.
        var groups: [String: String] = [:]
        for task in tasks {
            let jobID: String = task["jobID"]
            if steps[jobID] == nil { jobs.append(jobID) }
            let title: String = task["title"]
            let created: Double = task["createdAt"]
            let group = heading(task["groupLabel"])
            if let group, group != groups[jobID] {
                steps[jobID, default: []].append(
                    Step(
                        id: UUID().uuidString, text: group, isHeading: true, isTicked: false,
                        createdAt: created, updatedAt: created))
            }
            groups[jobID] = group
            let status: String = task["status"]
            steps[jobID, default: []].append(
                Step(
                    id: task["id"], text: title, isHeading: false,
                    isTicked: status == "Done" || status == "Skipped", createdAt: created,
                    updatedAt: task["updatedAt"]))
            if let text = entry(
                title: title, detail: task["detail"], waitingReason: task["waitingReason"],
                skippedReason: task["skippedReason"])
            {
                entries[jobID, default: []].append(text)
            }
        }
        for jobID in jobs {
            for (position, step) in (steps[jobID] ?? []).enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO checklistStep
                            (id, jobID, position, text, isHeading, isTicked, createdAt, updatedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        step.id, jobID, position, step.text, step.isHeading, step.isTicked,
                        step.createdAt, step.updatedAt,
                    ])
            }
            guard let found = entries[jobID], !found.isEmpty else { continue }
            let notes =
                try String.fetchOne(
                    db, sql: "SELECT notes FROM job WHERE id = ?", arguments: [jobID])
                ?? ""
            try db.execute(
                sql: "UPDATE job SET notes = ? WHERE id = ?",
                arguments: [OldRecordNotes.appending(found, to: notes), jobID])
        }
    }

    // A group label as a heading's text, or nil when it holds no text.
    static func heading(_ label: String?) -> String? {
        let text = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    // One task's removed values, after a line with its text, such as "Step · Clean the
    // movement" and "Skipped reason: Already clean". Nil when it had none.
    static func entry(
        title: String, detail: String?, waitingReason: String?, skippedReason: String?
    ) -> String? {
        var lines: [String] = []
        if let detail = OldRecordNotes.kept(detail) { lines.append("Detail: \(detail)") }
        if let reason = OldRecordNotes.kept(waitingReason) {
            lines.append("Waiting reason: \(reason)")
        }
        if let reason = OldRecordNotes.kept(skippedReason) {
            lines.append("Skipped reason: \(reason)")
        }
        guard !lines.isEmpty else { return nil }
        return (["Step · \(title)"] + lines).joined(separator: "\n")
    }

    private struct Step {
        let id: String
        let text: String
        let isHeading: Bool
        let isTicked: Bool
        let createdAt: Double
        let updatedAt: Double
    }
}
