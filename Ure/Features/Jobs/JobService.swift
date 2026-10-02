import Foundation

nonisolated enum JobError: LocalizedError, Equatable {
    case unavailableWatch
    case missingRecord
    case closedJob
    case unsupportedSnapshot
    case openJobExists(JobRecord)

    var errorDescription: String? {
        switch self {
        case .unavailableWatch: "This watch is no longer available. Your draft has been kept."
        case .missingRecord: "This job is no longer available. Your draft has been kept."
        case .closedJob: "This job is closed. Its intake cannot be changed."
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
                guard let existing = try JobQueries.fetch(id, in: db), existing.watchID == watchID
                else {
                    throw JobError.missingRecord
                }
                guard existing.stage.isOpen else { throw JobError.closedJob }
                guard existing.intakeSnapshot.version == 1 else {
                    throw JobError.unsupportedSnapshot
                }
                let snapshot = try draft.intake?.snapshot() ?? existing.intakeSnapshot
                let record = try draft.record(
                    id: id, watchID: watchID, stage: existing.stage, snapshot: snapshot,
                    createdAt: existing.createdAt, updatedAt: now)
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
}
