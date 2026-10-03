import Foundation

nonisolated enum WatchError: LocalizedError {
    case missingRecord
    case unavailableCaliber

    var errorDescription: String? {
        switch self {
        case .missingRecord:
            "This watch is no longer available. Your draft has been kept."
        case .unavailableCaliber:
            "This caliber is no longer available. Choose another caliber or clear the link."
        }
    }
}

nonisolated struct WatchService: Sendable {
    let coordinator: LibraryCoordinator

    func save(_ draft: WatchDraft, editing id: UUID?, locale: Locale = .current) async throws
        -> WatchRecord
    {
        try await coordinator.mutate { db, _, dependencies in
            if let caliberID = draft.caliberID {
                guard let caliber = try CaliberQueries.fetch(caliberID, in: db) else {
                    throw WatchError.unavailableCaliber
                }
                let previous = try id.flatMap { try WatchQueries.fetch($0, in: db) }
                if caliber.archivedAt != nil, previous?.caliberID != caliberID {
                    throw ArchiveError.archived
                }
            }
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            if let id {
                guard let existing = try WatchQueries.fetch(id, in: db) else {
                    throw WatchError.missingRecord
                }
                try RecordAccess.requireWatch(id, in: db)
                var record = try draft.record(
                    id: id, createdAt: existing.createdAt, updatedAt: now, locale: locale)
                record.condition = existing.condition
                record.conditionNote = existing.conditionNote
                record.coverPhotoID = existing.coverPhotoID
                try WatchQueries.update(record, in: db)
                return record
            }
            let record = try draft.record(
                id: dependencies.makeID(), createdAt: now, updatedAt: now, locale: locale)
            try WatchQueries.insert(record, in: db)
            return record
        }
    }
}
