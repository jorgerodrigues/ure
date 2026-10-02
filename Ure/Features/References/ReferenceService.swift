import AppKit
import Foundation
import GRDB

nonisolated enum ReferenceError: LocalizedError, Equatable {
    case unavailableOwner
    case missingRecord
    case ownerMismatch
    case invalidURL
    case browserUnavailable
    case notLink

    var errorDescription: String? {
        switch self {
        case .unavailableOwner:
            "This reference's owner is no longer available. Your draft has been kept."
        case .missingRecord: "This reference is no longer available. Your draft has been kept."
        case .ownerMismatch: "This reference belongs to another scope. Your draft has been kept."
        case .invalidURL: "This reference does not have a valid HTTP or HTTPS URL."
        case .browserUnavailable: "The default browser could not open this reference. Try again."
        case .notLink: "This item is not an external link."
        }
    }
}

nonisolated struct ReferenceService: Sendable {
    let coordinator: LibraryCoordinator
    var openBrowser: @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }

    func save(_ draft: ReferenceDraft, for owner: LibraryItemOwner, editing id: UUID?) async throws
        -> LibraryItem
    {
        try await coordinator.mutate { db, _, dependencies in
            switch owner {
            case .job(let id): _ = try JobService.requireOpenJob(id, in: db)
            case .watch(let id):
                guard try WatchQueries.fetch(id, in: db) != nil else {
                    throw ReferenceError.unavailableOwner
                }
            case .caliber(let id):
                guard try CaliberQueries.fetch(id, in: db) != nil else {
                    throw ReferenceError.unavailableOwner
                }
            }
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            if let id {
                guard let existing = try LibraryItemQueries.fetch(id, in: db) else {
                    throw ReferenceError.missingRecord
                }
                guard existing.belongs(to: owner) else { throw ReferenceError.ownerMismatch }
                guard existing.kind == .link else { throw ReferenceError.notLink }
                let record = try draft.record(
                    id: id, owner: owner, createdAt: existing.createdAt, updatedAt: now)
                try LibraryItemQueries.update(record, in: db)
                return record
            }
            let record = try draft.record(
                id: dependencies.makeID(), owner: owner, createdAt: now, updatedAt: now)
            try LibraryItemQueries.insert(record, in: db)
            return record
        }
    }

    @MainActor
    func open(_ item: LibraryItem) throws {
        guard item.kind == .link else { throw ReferenceError.notLink }
        guard let url = ReferenceDraft.parsedURL(item.sourceURL) else {
            throw ReferenceError.invalidURL
        }
        guard openBrowser(url) else { throw ReferenceError.browserUnavailable }
    }
}
