import Foundation

nonisolated enum WatchError: LocalizedError {
    case missingRecord

    var errorDescription: String? { "This watch is no longer available. Your draft has been kept." }
}

nonisolated struct WatchService: Sendable {
    let coordinator: LibraryCoordinator

    func save(_ draft: WatchDraft, editing id: UUID?, locale: Locale = .current) async throws
        -> WatchRecord
    {
        try await coordinator.mutate { db, _, dependencies in
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            if let id {
                guard let existing = try WatchQueries.fetch(id, in: db) else {
                    throw WatchError.missingRecord
                }
                let record = try draft.record(
                    id: id, createdAt: existing.createdAt, updatedAt: now, locale: locale)
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
