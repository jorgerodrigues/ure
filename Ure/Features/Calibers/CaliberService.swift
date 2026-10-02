import Foundation

nonisolated enum CaliberError: LocalizedError {
    case missingRecord

    var errorDescription: String? {
        "This caliber is no longer available. Your draft has been kept."
    }
}

nonisolated struct CaliberService: Sendable {
    let coordinator: LibraryCoordinator

    func save(_ draft: CaliberDraft, editing id: UUID?, locale: Locale = .current) async throws
        -> CaliberRecord
    {
        try await coordinator.mutate { db, _, dependencies in
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            if let id {
                guard let existing = try CaliberQueries.fetch(id, in: db) else {
                    throw CaliberError.missingRecord
                }
                let record = try draft.record(
                    id: id, createdAt: existing.createdAt, updatedAt: now, locale: locale)
                try CaliberQueries.update(record, in: db)
                return record
            }
            let record = try draft.record(
                id: dependencies.makeID(), createdAt: now, updatedAt: now, locale: locale)
            try CaliberQueries.insert(record, in: db)
            return record
        }
    }
}
