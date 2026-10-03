import Foundation

nonisolated struct JobTransitionDraft: Equatable, Sendable {
    var stage: JobStage
    var waitingReason = ""
    var outcome = ""
    var recommendations = ""
    var cancellationReason = ""
    var unfinishedTasksReason = ""
    var unfinishedPartsReason = ""

    init(stage: JobStage) { self.stage = stage }

    init(job: JobRecord) {
        stage = job.stage
        waitingReason = job.waitingReason ?? ""
        outcome = job.outcome ?? ""
        recommendations = job.recommendations ?? ""
        cancellationReason = job.cancellationReason ?? ""
    }

    func validate(hasUnfinishedTasks: Bool = false, hasUnresolvedParts: Bool = false) throws {
        var fields: [JobField: String] = [:]
        if stage == .waiting && JobDraft.optional(waitingReason) == nil {
            fields[.waitingReason] = "Enter a waiting reason."
        }
        if stage == .completed && JobDraft.optional(outcome) == nil {
            fields[.outcome] = "Enter the repair outcome."
        }
        if stage == .cancelled && JobDraft.optional(cancellationReason) == nil {
            fields[.cancellationReason] = "Enter a cancellation reason."
        }
        if !stage.isOpen && hasUnfinishedTasks && JobDraft.optional(unfinishedTasksReason) == nil {
            fields[.unfinishedTasksReason] = "Explain why these tasks will stay unfinished."
        }
        if !stage.isOpen && hasUnresolvedParts && JobDraft.optional(unfinishedPartsReason) == nil {
            fields[.unfinishedPartsReason] = "Explain why these parts will stay unresolved."
        }
        guard fields.isEmpty else { throw JobValidationError(fields: fields) }
    }
}

nonisolated struct WatchConditionDraft: Equatable, Sendable {
    var condition: WatchCondition
    var note: String
}

nonisolated enum JobAction: Sendable {
    case transition
    case reopen
    case condition
}

nonisolated struct JobActionDraft: Equatable, Sendable {
    let action: JobAction
    var transition: JobTransitionDraft
    var condition: WatchConditionDraft

    init(action: JobAction, job: JobRecord, watch: WatchRecord) {
        self.action = action
        transition = JobTransitionDraft(job: job)
        if action == .reopen { transition.stage = .inProgress }
        condition = WatchConditionDraft(condition: watch.condition, note: watch.conditionNote ?? "")
    }
}
