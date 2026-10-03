import Foundation
import GRDB

nonisolated enum JobTaskMove: Sendable {
    case up
    case down
    case before(UUID)
    case end
}

nonisolated enum JobTaskError: LocalizedError, Equatable {
    case missingRecord
    case jobMismatch
    case missingPart
    case partJobMismatch

    var errorDescription: String? {
        switch self {
        case .missingRecord: "This task is no longer available. Your draft has been kept."
        case .jobMismatch: "This task belongs to another job. Your draft has been kept."
        case .missingPart: "A linked part is no longer available. Your draft has been kept."
        case .partJobMismatch:
            "Linked parts must belong to this task's job. Your draft has been kept."
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
            let savedLinks =
                try existing.map { try TaskPartQueries.linked(to: $0.id, in: db) } ?? []
            let savedPartIDs = Set(savedLinks.map(\.partID))
            var linkedParts: [PartRecord] = []
            for partID in draft.partIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard
                    let part = try PartRecord.fetchOne(
                        db, sql: "SELECT * FROM partRequirement WHERE id = ?",
                        arguments: [partID.uuidString])
                else { throw JobTaskError.missingPart }
                guard part.jobID == jobID else { throw JobTaskError.partJobMismatch }
                linkedParts.append(part)
            }
            let retainsWaitingLinks =
                existing?.status == .waiting && existing?.waitingReason == nil
                && !savedPartIDs.isEmpty
                && savedPartIDs.isSubset(of: draft.partIDs)
            let record = try draft.record(
                id: existing?.id ?? dependencies.makeID(), jobID: jobID,
                position: try existing?.position
                    ?? JobTaskQueries.ordered(for: jobID, in: db).count,
                createdAt: existing?.createdAt ?? now, updatedAt: now,
                allowsLinkedWaiting: linkedParts.contains { $0.status.isUnresolved }
                    || retainsWaitingLinks)
            if let existing, JobTaskDraft(task: existing) == JobTaskDraft(task: record),
                savedPartIDs == draft.partIDs
            {
                return existing
            }
            if existing != nil {
                try record.update(db)
            } else {
                try record.insert(db)
            }
            for partID in savedPartIDs.subtracting(draft.partIDs) {
                try db.execute(
                    sql: "DELETE FROM taskPart WHERE taskID = ? AND partID = ?",
                    arguments: [record.id.uuidString, partID.uuidString])
            }
            for partID in draft.partIDs.subtracting(savedPartIDs) {
                try TaskPart(taskID: record.id, partID: partID).insert(db)
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

    func move(_ id: UUID, for jobID: UUID, to destination: JobTaskMove) async throws
        -> [JobTaskRecord]
    {
        try await coordinator.mutate { db, _, _ in
            _ = try JobService.requireOpenJob(jobID, in: db)
            guard let task = try JobTaskQueries.fetch(id, in: db) else {
                throw JobTaskError.missingRecord
            }
            guard task.jobID == jobID else { throw JobTaskError.jobMismatch }
            var records = try JobTaskQueries.ordered(for: jobID, in: db)
            guard let source = records.firstIndex(where: { $0.id == id }) else {
                throw JobTaskError.missingRecord
            }
            var target: Int
            switch destination {
            case .up: target = max(0, source - 1)
            case .down: target = min(records.count - 1, source + 1)
            case .end: target = records.count - 1
            case .before(let targetID):
                guard let targetTask = try JobTaskQueries.fetch(targetID, in: db) else {
                    throw JobTaskError.missingRecord
                }
                guard targetTask.jobID == jobID else { throw JobTaskError.jobMismatch }
                guard let index = records.firstIndex(where: { $0.id == targetID }) else {
                    throw JobTaskError.missingRecord
                }
                target = index
                if source < target { target -= 1 }
            }
            guard source != target else { return records }
            records.insert(records.remove(at: source), at: target)
            for (position, record) in records.enumerated() where record.position != position {
                try db.execute(
                    sql: "UPDATE jobTask SET position = ? WHERE id = ?",
                    arguments: [position, record.id.uuidString])
            }
            return try JobTaskQueries.ordered(for: jobID, in: db)
        }
    }
}
