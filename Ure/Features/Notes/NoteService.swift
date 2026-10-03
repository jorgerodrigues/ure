import Foundation
import GRDB

nonisolated enum NoteError: LocalizedError, Equatable {
    case unavailableOwner
    case missingRecord
    case ownerMismatch

    var errorDescription: String? {
        switch self {
        case .unavailableOwner:
            "This note's owner is no longer available. Your draft has been kept."
        case .missingRecord: "This note is no longer available. Your draft has been kept."
        case .ownerMismatch: "This note belongs to another scope. Your draft has been kept."
        }
    }
}

nonisolated struct NoteService: Sendable {
    let coordinator: LibraryCoordinator

    func save(_ draft: NoteDraft, for owner: NoteOwner, editing id: UUID?) async throws
        -> NoteRecord
    {
        try await coordinator.mutate { db, _, dependencies in
            switch owner {
            case .job(let id): _ = try JobService.requireOpenJob(id, in: db)
            case .watch(let id):
                guard try WatchQueries.fetch(id, in: db) != nil else {
                    throw NoteError.unavailableOwner
                }
                try RecordAccess.requireWatch(id, in: db)
            case .caliber(let id):
                guard try CaliberQueries.fetch(id, in: db) != nil else {
                    throw NoteError.unavailableOwner
                }
                try RecordAccess.requireCaliber(id, in: db)
            }
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            if let id {
                guard let existing = try NoteQueries.fetch(id, in: db) else {
                    throw NoteError.missingRecord
                }
                guard existing.belongs(to: owner) else { throw NoteError.ownerMismatch }
                let record = try draft.record(
                    id: id, owner: owner, createdAt: existing.createdAt, updatedAt: now)
                try NoteQueries.update(record, in: db)
                return record
            }
            let record = try draft.record(
                id: dependencies.makeID(), owner: owner, createdAt: now, updatedAt: now)
            try NoteQueries.insert(record, in: db)
            return record
        }
    }
}
