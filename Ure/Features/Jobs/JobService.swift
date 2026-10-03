import Foundation
import GRDB

nonisolated enum JobError: LocalizedError, Equatable {
    case unavailableWatch
    case missingRecord
    case closedJob
    case notClosed
    case invalidReopenStage
    case unsupportedSnapshot
    case openJobExists(JobRecord)

    var errorDescription: String? {
        switch self {
        case .unavailableWatch: "This watch is no longer available. Your draft has been kept."
        case .missingRecord: "This job is no longer available. Your draft has been kept."
        case .closedJob: "This job is closed. Reopen it before making changes."
        case .notClosed: "This job is already open."
        case .invalidReopenStage: "Choose an open stage when reopening a job."
        case .unsupportedSnapshot:
            "This job uses an unsupported intake version. Its data has been kept."
        case .openJobExists:
            "This watch already has an open job. Open that job to continue its repair."
        }
    }
}

nonisolated struct JobService: Sendable {
    let coordinator: LibraryCoordinator

    func save(_ draft: JobDraft, for watchID: UUID, editing id: UUID?) async throws -> JobRecord {
        try await coordinator.mutate { db, _, dependencies in
            guard let watch = try WatchQueries.fetch(watchID, in: db) else {
                throw JobError.unavailableWatch
            }
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            if let id {
                let existing = try Self.requireOpenJob(id, in: db)
                guard existing.watchID == watchID else { throw JobError.missingRecord }
                guard existing.intakeSnapshot.version == 1 else {
                    throw JobError.unsupportedSnapshot
                }
                let snapshot = try draft.intake?.snapshot() ?? existing.intakeSnapshot
                let record = try draft.record(
                    id: id, watchID: watchID, stage: existing.stage, snapshot: snapshot,
                    createdAt: existing.createdAt, updatedAt: now, existing: existing)
                try JobQueries.update(record, in: db)
                return record
            }
            if let existing = try JobQueries.openJob(for: watchID, in: db) {
                throw JobError.openJobExists(existing)
            }
            var caliber: CaliberRecord?
            if let caliberID = watch.caliberID {
                caliber = try CaliberQueries.fetch(caliberID, in: db)
            }
            let record = try draft.record(
                id: dependencies.makeID(), watchID: watchID, stage: .planned,
                snapshot: JobIntakeSnapshot(watch: watch, caliber: caliber),
                createdAt: now, updatedAt: now)
            try JobQueries.insert(record, in: db)
            return record
        }
    }

    static func requireOpenJob(_ id: UUID, in db: Database) throws -> JobRecord {
        guard let job = try JobQueries.fetch(id, in: db) else { throw JobError.missingRecord }
        guard job.stage.isOpen else { throw JobError.closedJob }
        return job
    }

    func transition(_ id: UUID, using draft: JobTransitionDraft) async throws -> JobRecord {
        try await coordinator.mutate { db, _, dependencies in
            let existing = try Self.requireOpenJob(id, in: db)
            return try Self.changeStage(existing, using: draft, in: db, dependencies: dependencies)
        }
    }

    func reopen(_ id: UUID, using draft: JobTransitionDraft) async throws -> JobRecord {
        try await coordinator.mutate { db, _, dependencies in
            guard let existing = try JobQueries.fetch(id, in: db) else {
                throw JobError.missingRecord
            }
            guard !existing.stage.isOpen else { throw JobError.notClosed }
            guard draft.stage.isOpen else { throw JobError.invalidReopenStage }
            if let open = try JobQueries.openJob(for: existing.watchID, in: db) {
                throw JobError.openJobExists(open)
            }
            return try Self.changeStage(existing, using: draft, in: db, dependencies: dependencies)
        }
    }

    func setCondition(_ id: UUID, using draft: WatchConditionDraft) async throws -> WatchRecord {
        try await coordinator.mutate { db, _, dependencies in
            let job = try Self.requireOpenJob(id, in: db)
            guard var watch = try WatchQueries.fetch(job.watchID, in: db) else {
                throw JobError.unavailableWatch
            }
            let prior = WatchConditionValue(watch: watch)
            watch.condition = draft.condition
            watch.conditionNote = JobDraft.optional(draft.note)
            let next = WatchConditionValue(watch: watch)
            guard prior != next else { return watch }
            watch.updatedAt = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            try WatchQueries.update(watch, in: db)
            try ActivityQueries.insert(
                jobID: id, kind: .watchConditionChanged, prior: .condition(prior),
                next: .condition(next),
                in: db, dependencies: dependencies)
            return watch
        }
    }

    private static func changeStage(
        _ existing: JobRecord, using draft: JobTransitionDraft, in db: Database,
        dependencies: LibraryDependencies
    ) throws -> JobRecord {
        let unfinished = try JobTaskQueries.unfinished(for: existing.id, in: db)
        let unresolved = try PartQueries.unresolved(for: existing.id, in: db)
        try draft.validate(
            hasUnfinishedTasks: !unfinished.isEmpty, hasUnresolvedParts: !unresolved.isEmpty)
        var job = existing
        job.stage = draft.stage
        job.waitingReason = nil
        if draft.stage == .waiting { job.waitingReason = JobDraft.optional(draft.waitingReason) }
        job.cancellationReason = nil
        job.unfinishedTasksReason = nil
        job.unfinishedPartsReason = nil
        if !draft.stage.isOpen && !unresolved.isEmpty {
            job.unfinishedPartsReason = JobDraft.optional(draft.unfinishedPartsReason)
        }
        if !draft.stage.isOpen && !unfinished.isEmpty {
            job.unfinishedTasksReason = JobDraft.optional(draft.unfinishedTasksReason)
        }
        let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
        if draft.stage == .inProgress && job.startedAt == nil { job.startedAt = now }
        if draft.stage.isOpen {
            job.completedAt = nil
            job.cancelledAt = nil
        } else if draft.stage == .completed {
            job.outcome = JobDraft.optional(draft.outcome)
            job.recommendations = JobDraft.optional(draft.recommendations)
            job.completedAt = now
            job.cancelledAt = nil
        } else {
            job.cancellationReason = JobDraft.optional(draft.cancellationReason)
            job.cancelledAt = now
            job.completedAt = nil
        }
        let prior = JobStageValue(job: existing)
        let next = JobStageValue(job: job)
        guard prior != next else { return existing }
        job.updatedAt = now
        try JobQueries.updateWorkflow(job, in: db)
        try ActivityQueries.insert(
            jobID: job.id, kind: .jobStageChanged, prior: .job(prior), next: .job(next),
            in: db, dependencies: dependencies)
        return job
    }
}
