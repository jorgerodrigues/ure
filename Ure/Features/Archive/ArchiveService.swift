import Foundation
import GRDB

nonisolated enum ArchiveError: LocalizedError, Equatable {
    case archived
    case openJob
    case missingRecord

    var errorDescription: String? {
        switch self {
        case .archived: "This record is archived. Unarchive it before making changes."
        case .openJob: "Close the watch's open job before archiving it."
        case .missingRecord: "This record is no longer available."
        }
    }
}

nonisolated enum RecordAccess {
    static func requireWatch(_ id: UUID, in db: Database) throws {
        guard let watch = try WatchQueries.fetch(id, in: db) else {
            throw ArchiveError.missingRecord
        }
        guard watch.archivedAt == nil else { throw ArchiveError.archived }
    }

    static func requireCaliber(_ id: UUID, in db: Database) throws {
        guard let caliber = try CaliberQueries.fetch(id, in: db) else {
            throw ArchiveError.missingRecord
        }
        guard caliber.archivedAt == nil else { throw ArchiveError.archived }
    }

    static func requireOwner(_ owner: LibraryItemOwner, in db: Database) throws {
        switch owner {
        case .watch(let id): try requireWatch(id, in: db)
        case .caliber(let id): try requireCaliber(id, in: db)
        case .job(let id): _ = try JobService.requireOpenJob(id, in: db)
        }
    }
}

nonisolated struct ArchiveService: Sendable {
    let coordinator: LibraryCoordinator

    func setWatch(_ id: UUID, archived: Bool) async throws -> WatchRecord {
        try await coordinator.mutate { db, _, dependencies in
            guard var watch = try WatchQueries.fetch(id, in: db) else {
                throw ArchiveError.missingRecord
            }
            if archived, try JobQueries.openJob(for: id, in: db) != nil {
                throw ArchiveError.openJob
            }
            guard (watch.archivedAt != nil) != archived else { return watch }
            watch.archivedAt =
                archived
                ? Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970) : nil
            try WatchQueries.update(watch, in: db)
            return watch
        }
    }

    func setCaliber(_ id: UUID, archived: Bool) async throws -> CaliberRecord {
        try await coordinator.mutate { db, _, dependencies in
            guard var caliber = try CaliberQueries.fetch(id, in: db) else {
                throw ArchiveError.missingRecord
            }
            guard (caliber.archivedAt != nil) != archived else { return caliber }
            caliber.archivedAt =
                archived
                ? Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970) : nil
            try CaliberQueries.update(caliber, in: db)
            return caliber
        }
    }
}
