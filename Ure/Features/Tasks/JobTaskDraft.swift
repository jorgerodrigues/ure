import Foundation

nonisolated enum JobTaskField: Hashable {
    case title
    case waitingReason
    case skippedReason
}

nonisolated struct JobTaskValidationError: LocalizedError {
    let fields: [JobTaskField: String]
    var errorDescription: String? { "Check the marked fields. Your draft has been kept." }
}

nonisolated struct JobTaskDraft: Equatable, Sendable {
    var title = ""
    var detail = ""
    var groupLabel = ""
    var status: JobTaskStatus = .toDo
    var waitingReason = ""
    var skippedReason = ""

    init() {}

    init(task: JobTaskRecord) {
        title = task.title
        detail = task.detail ?? ""
        groupLabel = task.groupLabel ?? ""
        status = task.status
        waitingReason = task.waitingReason ?? ""
        skippedReason = task.skippedReason ?? ""
    }

    func record(id: UUID, jobID: UUID, createdAt: Date, updatedAt: Date) throws -> JobTaskRecord {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [JobTaskField: String] = [:]
        if title.isEmpty { fields[.title] = "Enter a task title." }
        if status == .waiting && JobDraft.optional(waitingReason) == nil {
            fields[.waitingReason] = "Enter a waiting reason."
        }
        if status == .skipped && JobDraft.optional(skippedReason) == nil {
            fields[.skippedReason] = "Enter a skipped reason."
        }
        guard fields.isEmpty else { throw JobTaskValidationError(fields: fields) }
        return JobTaskRecord(
            id: id, jobID: jobID, title: title, detail: JobDraft.optional(detail),
            groupLabel: JobDraft.optional(groupLabel), status: status,
            waitingReason: status == .waiting ? JobDraft.optional(waitingReason) : nil,
            skippedReason: status == .skipped ? JobDraft.optional(skippedReason) : nil,
            createdAt: createdAt, updatedAt: updatedAt)
    }
}
