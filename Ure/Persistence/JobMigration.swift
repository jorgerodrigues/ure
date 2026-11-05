import Foundation
import GRDB

// Before v23, a job moved through six stages. It kept an intake snapshot, an agreed scope, an
// intake condition, an outcome, recommendations, a cancellation reason and two unfinished
// reasons, and an activity history beside it. A job now has three states. Planned, In progress
// and Ready become In progress, Waiting stays Waiting, and Completed and Cancelled become Done.
// The removed values, and the reasons typed into the history that no record holds any more, are
// written into the job's notes, so nothing typed is lost.
nonisolated enum JobMigration {
    static func preserveRemovedFields(in db: Database, locale: Locale, timeZone: TimeZone) throws {
        let history = try JobHistory.lines(in: db, locale: locale, timeZone: timeZone)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT job.id AS id, job.stage AS stage, job.agreedScope AS agreedScope,
                    job.intakeCondition AS intakeCondition, job.intakeSnapshot AS intakeSnapshot,
                    job.waitingReason AS waitingReason, job.outcome AS outcome,
                    job.recommendations AS recommendations,
                    job.cancellationReason AS cancellationReason,
                    job.unfinishedTasksReason AS unfinishedTasksReason,
                    job.unfinishedPartsReason AS unfinishedPartsReason, job.notes AS notes,
                    watch.name AS watchName, watch.brand AS brand, watch.model AS model,
                    watch.caseReference AS caseReference, watch.serial AS serial,
                    caliber.designation AS caliber
                FROM job JOIN watch ON watch.id = job.watchID
                LEFT JOIN caliber ON caliber.id = watch.caliberID
                ORDER BY job.createdAt, job.id
                """)
        for row in rows {
            let id: String = row["id"]
            let watch = IntakeWatch(
                name: row["watchName"], brand: row["brand"], model: row["model"],
                caseReference: row["caseReference"], serial: row["serial"],
                caliber: row["caliber"])
            let fields = entry(
                stage: row["stage"], agreedScope: row["agreedScope"],
                intakeCondition: row["intakeCondition"],
                intake: intake(row["intakeSnapshot"], watch: watch),
                waitingReason: row["waitingReason"], outcome: row["outcome"],
                recommendations: row["recommendations"],
                cancellationReason: row["cancellationReason"],
                unfinishedTasksReason: row["unfinishedTasksReason"],
                unfinishedPartsReason: row["unfinishedPartsReason"])
            var entries = fields.map { [$0] } ?? []
            if let lines = history[id], !lines.isEmpty {
                entries.append((["History"] + lines).joined(separator: "\n"))
            }
            guard !entries.isEmpty else { continue }
            let notes: String = row["notes"]
            try db.execute(
                sql: "UPDATE job SET notes = ? WHERE id = ?",
                arguments: [OldRecordNotes.appending(entries, to: notes), id])
        }
    }

    // One line per removed job value, such as "Outcome: Serviced and regulated". The waiting
    // reason of a waiting job stays as its "Waiting for" text, so only another job's is written.
    // A cancelled job says so, with its reason. Nil when the job had none.
    static func entry(
        stage: String, agreedScope: String?, intakeCondition: String?, intake: [String],
        waitingReason: String?, outcome: String?, recommendations: String?,
        cancellationReason: String?, unfinishedTasksReason: String?,
        unfinishedPartsReason: String?
    ) -> String? {
        var lines: [String] = []
        func add(_ label: String, _ value: String?) {
            if let value = OldRecordNotes.kept(value) { lines.append("\(label): \(value)") }
        }
        add("Agreed scope", agreedScope)
        add("Intake condition", intakeCondition)
        lines += intake
        if stage != "Waiting" { add("Waiting reason", waitingReason) }
        add("Outcome", outcome)
        add("Recommendations", recommendations)
        if stage == "Cancelled" {
            lines.append(
                OldRecordNotes.kept(cancellationReason).map { "Cancelled: \($0)" } ?? "Cancelled")
        } else {
            add("Cancellation reason", cancellationReason)
        }
        add("Unfinished tasks", unfinishedTasksReason)
        add("Unresolved parts", unfinishedPartsReason)
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    // The values the job saved at intake that differ from its watch now, one line each, such as
    // "Serial at intake: 14 500 123". Values the watch still holds are not repeated. A snapshot
    // this version can't read is written as it was saved.
    static func intake(_ snapshot: String, watch: IntakeWatch) -> [String] {
        guard let saved = try? JSONDecoder().decode(IntakeSnapshot.self, from: Data(snapshot.utf8)),
            saved.version == 1
        else { return ["Intake snapshot: \(snapshot)"] }
        var lines: [String] = []
        func add(_ label: String, _ value: String?, now current: String?) {
            guard let value = OldRecordNotes.kept(value), trimmed(value) != trimmed(current)
            else { return }
            lines.append("\(label) at intake: \(value)")
        }
        add("Watch name", saved.watchName, now: watch.name)
        add("Brand", saved.brand, now: watch.brand)
        add("Model", saved.model, now: watch.model)
        add("Reference", saved.caseReference, now: watch.caseReference)
        add("Serial", saved.serial, now: watch.serial)
        add("Caliber", saved.caliberDesignation, now: watch.caliber)
        add("Caliber variant", saved.caliberVariant, now: nil)
        return lines
    }

    private static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// What a watch holds now that an intake snapshot copied.
nonisolated struct IntakeWatch {
    let name: String
    let brand: String?
    let model: String?
    let caseReference: String?
    let serial: String?
    let caliber: String?
}

// The intake snapshot as jobs before v23 saved it.
nonisolated private struct IntakeSnapshot: Decodable {
    let version: Int
    let watchName: String?
    let brand: String?
    let model: String?
    let caseReference: String?
    let serial: String?
    let caliberDesignation: String?
    let caliberVariant: String?
}

// The reasons typed into the activity history before v23 that no record holds any more. The
// history recorded each change of a job's stage, a watch's condition, a task's status and a
// part's status, with the values before and after it.
nonisolated enum JobHistory {
    // For each job, one line per reason, oldest first, such as
    // "14 October 2026 · Waiting reason: Mainspring on order". A reason that the job, the task
    // or the part still holds in the same field is not repeated, and neither is a line the job
    // already has. A history value this version can't read is written as it was saved.
    static func lines(in db: Database, locale: Locale, timeZone: TimeZone) throws
        -> [String: [String]]
    {
        let kept = try KeptValues(in: db)
        let events = try Row.fetchAll(
            db,
            sql:
                "SELECT jobID, occurredAt, priorValue, nextValue FROM activityEvent ORDER BY ordering"
        )
        var lines: [String: [String]] = [:]
        var seen: [String: Set<String>] = [:]
        for event in events {
            let jobID: String = event["jobID"]
            let date = day(Date(timeIntervalSince1970: event["occurredAt"]), locale, timeZone)
            for column in ["priorValue", "nextValue"] {
                let raw: String = event[column]
                for reason in reasons(in: raw, jobID: jobID, kept: kept) {
                    guard seen[jobID, default: []].insert(reason).inserted else { continue }
                    lines[jobID, default: []].append("\(date) · \(reason)")
                }
            }
        }
        return lines
    }

    // The reasons one history value holds that its record does not, such as
    // "Task · Clean the movement · Skipped reason: Already clean".
    static func reasons(in raw: String, jobID: String, kept: KeptValues) -> [String] {
        guard let value = try? JSONDecoder().decode(HistoryValue.self, from: Data(raw.utf8))
        else { return ["History entry: \(raw)"] }
        var found: [String] = []
        func add(_ label: String, _ text: String?, keeps current: String?) {
            guard let text = OldRecordNotes.kept(text), text != OldRecordNotes.kept(current)
            else { return }
            found.append("\(label): \(text)")
        }
        if let job = value.job?.value {
            let current = kept.jobs[jobID]
            add("Waiting reason", job.waitingReason, keeps: current?.waitingReason)
            add("Outcome", job.outcome, keeps: current?.outcome)
            add("Recommendations", job.recommendations, keeps: current?.recommendations)
            add(
                "Cancellation reason", job.cancellationReason,
                keeps: current?.cancellationReason)
            add(
                "Unfinished tasks", job.unfinishedTasksReason,
                keeps: current?.unfinishedTasksReason)
            add(
                "Unresolved parts", job.unfinishedPartsReason,
                keeps: current?.unfinishedPartsReason)
        }
        if let condition = value.condition?.value {
            add("Condition note", condition.note, keeps: nil)
        }
        if let task = value.task?.value {
            let current = task.taskID.flatMap { kept.tasks[$0] }
            let label = "Task · \(task.title ?? "Removed task")"
            add("\(label) · Waiting reason", task.waitingReason, keeps: current?.waitingReason)
            add("\(label) · Skipped reason", task.skippedReason, keeps: current?.skippedReason)
        }
        if let part = value.part?.value {
            let current = part.partID.flatMap { kept.parts[$0] }
            let label = "Part · \(part.description ?? "Removed part")"
            add("\(label) · Status reason", part.reason, keeps: current?.statusReason)
            add(
                "\(label) · Order reference", part.orderReference,
                keeps: current?.orderReference)
        }
        return found
    }

    private static func day(_ date: Date, _ locale: Locale, _ timeZone: TimeZone) -> String {
        var calendar = locale.calendar
        calendar.timeZone = timeZone
        return date.formatted(
            Date.FormatStyle(
                date: .long, time: .omitted, locale: locale, calendar: calendar,
                timeZone: timeZone))
    }
}

// The reasons that jobs, tasks and parts still hold before v23. The job's own go into its notes
// as removed values, and the task and part reasons stay on those records.
nonisolated struct KeptValues {
    struct JobReasons {
        let waitingReason: String?
        let outcome: String?
        let recommendations: String?
        let cancellationReason: String?
        let unfinishedTasksReason: String?
        let unfinishedPartsReason: String?
    }

    struct TaskReasons {
        let waitingReason: String?
        let skippedReason: String?
    }

    struct PartReasons {
        let statusReason: String?
        let orderReference: String?
    }

    var jobs: [String: JobReasons] = [:]
    var tasks: [UUID: TaskReasons] = [:]
    var parts: [UUID: PartReasons] = [:]

    init() {}

    init(in db: Database) throws {
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT id, waitingReason, outcome, recommendations, cancellationReason,
                    unfinishedTasksReason, unfinishedPartsReason
                FROM job
                """)
        {
            jobs[row["id"]] = JobReasons(
                waitingReason: row["waitingReason"], outcome: row["outcome"],
                recommendations: row["recommendations"],
                cancellationReason: row["cancellationReason"],
                unfinishedTasksReason: row["unfinishedTasksReason"],
                unfinishedPartsReason: row["unfinishedPartsReason"])
        }
        for row in try Row.fetchAll(
            db, sql: "SELECT id, waitingReason, skippedReason FROM jobTask")
        {
            guard let id = UUID(uuidString: row["id"]) else { continue }
            tasks[id] = TaskReasons(
                waitingReason: row["waitingReason"], skippedReason: row["skippedReason"])
        }
        for row in try Row.fetchAll(
            db, sql: "SELECT id, statusReason, orderReference FROM partRequirement")
        {
            guard let id = UUID(uuidString: row["id"]) else { continue }
            parts[id] = PartReasons(
                statusReason: row["statusReason"], orderReference: row["orderReference"])
        }
    }
}

// A history value as the activity records before v23 saved it: one of a job's stage, a watch's
// condition, a task's status or a part's status, under its case name.
nonisolated private struct HistoryValue: Decodable {
    let job: Saved<StageValue>?
    let condition: Saved<ConditionValue>?
    let task: Saved<TaskValue>?
    let part: Saved<PartValue>?
}

nonisolated private struct Saved<Value: Decodable>: Decodable {
    let value: Value

    enum CodingKeys: String, CodingKey {
        case value = "_0"
    }
}

nonisolated private struct StageValue: Decodable {
    let waitingReason: String?
    let outcome: String?
    let recommendations: String?
    let cancellationReason: String?
    let unfinishedTasksReason: String?
    let unfinishedPartsReason: String?
}

nonisolated private struct ConditionValue: Decodable {
    let note: String?
}

nonisolated private struct TaskValue: Decodable {
    let taskID: UUID?
    let title: String?
    let waitingReason: String?
    let skippedReason: String?
}

nonisolated private struct PartValue: Decodable {
    let partID: UUID?
    let description: String?
    let reason: String?
    let orderReference: String?
}
