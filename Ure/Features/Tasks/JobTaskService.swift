import Foundation
import GRDB

nonisolated enum JobTaskError: LocalizedError, Equatable {
    case missingRecord
    case jobMismatch

    var errorDescription: String? {
        switch self {
        case .missingRecord: "This task is no longer available. Your draft has been kept."
        case .jobMismatch: "This task belongs to another job. Your draft has been kept."
        }
    }
}

nonisolated struct JobTaskService: Sendable {
    let coordinator: LibraryCoordinator

    func save(_ draft: JobTaskDraft, for jobID: UUID, editing id: UUID?) async throws
        -> JobTaskRecord
    {
        try await coordinator.mutate { db, _, dependencies in
            _ = try JobService.requireOpenJob(jobID, in: db)
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            var existing: JobTaskRecord?
            if let id {
                guard let task = try JobTaskQueries.fetch(id, in: db) else {
                    throw JobTaskError.missingRecord
                }
                guard task.jobID == jobID else { throw JobTaskError.jobMismatch }
                existing = task
            }
            let record = try draft.record(
                id: existing?.id ?? dependencies.makeID(), jobID: jobID,
                createdAt: existing?.createdAt ?? now, updatedAt: now)
            if let existing, JobTaskDraft(task: existing) == JobTaskDraft(task: record) {
                return existing
            }
            if existing != nil {
                try record.update(db)
            } else {
                try record.insert(db)
            }
            if let existing {
                let prior = JobTaskValue(task: existing)
                let next = JobTaskValue(task: record)
                if prior.status != next.status || prior.waitingReason != next.waitingReason
                    || prior.skippedReason != next.skippedReason
                {
                    try ActivityQueries.insert(
                        jobID: jobID, kind: .taskStatusChanged, prior: .task(prior),
                        next: .task(next),
                        in: db, dependencies: dependencies)
                }
            } else if record.status == .done {
                try ActivityQueries.insert(
                    jobID: jobID, kind: .taskStatusChanged,
                    prior: .task(JobTaskValue(newTask: record)),
                    next: .task(JobTaskValue(task: record)),
                    in: db, dependencies: dependencies)
            }
            return record
        }
    }
}
