import Foundation

nonisolated struct RecordNotesService: Sendable {
    let coordinator: LibraryCoordinator

    func text(for owner: LibraryItemOwner) async throws -> String {
        try await coordinator.read { db in
            guard let text = try RecordNotesQueries.fetch(owner, in: db) else {
                throw ArchiveError.missingRecord
            }
            return text
        }
    }

    func save(_ text: String, for owner: LibraryItemOwner) async throws {
        try await coordinator.mutate { db, _, dependencies in
            try RecordAccess.requireOwner(owner, in: db)
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            try RecordNotesQueries.update(text, for: owner, at: now, in: db)
        }
    }
}
