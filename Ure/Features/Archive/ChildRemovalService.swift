import Foundation
import GRDB

nonisolated enum RemovalError: LocalizedError, Equatable {
    case missingRecord
    case scopeMismatch
    case changedLinks

    var errorDescription: String? {
        switch self {
        case .missingRecord: "This item is no longer available."
        case .scopeMismatch: "This item belongs to another scope."
        case .changedLinks: "The task's linked parts changed. Review the confirmation again."
        }
    }
}

nonisolated struct ChildRemovalService: Sendable {
    let coordinator: LibraryCoordinator

    func removeNote(_ id: UUID, for owner: NoteOwner) async throws {
        try await coordinator.mutate { db, _, _ in
            let itemOwner: LibraryItemOwner
            switch owner {
            case .watch(let id): itemOwner = .watch(id)
            case .job(let id): itemOwner = .job(id)
            case .caliber(let id): itemOwner = .caliber(id)
            }
            try RecordAccess.requireOwner(itemOwner, in: db)
            guard let note = try NoteQueries.fetch(id, in: db) else {
                throw RemovalError.missingRecord
            }
            guard note.belongs(to: owner) else { throw RemovalError.scopeMismatch }
            _ = try note.delete(db)
        }
    }

    func removeTask(_ id: UUID, for jobID: UUID, confirmedPartIDs: Set<UUID>) async throws
        -> [JobTaskRecord]
    {
        try await coordinator.mutate { db, _, _ in
            _ = try JobService.requireOpenJob(jobID, in: db)
            guard let task = try JobTaskQueries.fetch(id, in: db) else {
                throw RemovalError.missingRecord
            }
            guard task.jobID == jobID else { throw RemovalError.scopeMismatch }
            let links = try TaskPartQueries.linked(to: id, in: db)
            guard Set(links.map(\.partID)) == confirmedPartIDs else {
                throw RemovalError.changedLinks
            }
            try db.execute(sql: "DELETE FROM taskPart WHERE taskID = ?", arguments: [id.uuidString])
            _ = try task.delete(db)
            for (position, record) in try JobTaskQueries.ordered(for: jobID, in: db).enumerated() {
                try db.execute(
                    sql: "UPDATE jobTask SET position = ? WHERE id = ?",
                    arguments: [position, record.id.uuidString])
            }
            return try JobTaskQueries.ordered(for: jobID, in: db)
        }
    }

    func removeItem(_ id: UUID, for owner: LibraryItemOwner, kind: LibraryItemKind) async throws {
        try await coordinator.mutate { db, _, _ in
            try RecordAccess.requireOwner(owner, in: db)
            guard let item = try LibraryItemQueries.fetch(id, in: db) else {
                throw RemovalError.missingRecord
            }
            guard item.belongs(to: owner), item.kind == kind else {
                throw RemovalError.scopeMismatch
            }
            _ = try item.delete(db)
            if let assetID = item.fileAssetID {
                try db.execute(
                    sql: """
                        DELETE FROM fileAsset WHERE id = ?
                          AND NOT EXISTS (SELECT 1 FROM libraryItem WHERE fileAssetID = ?)
                        """, arguments: [assetID.uuidString, assetID.uuidString])
            }
        }
        // Unreferenced generated originals are the durable cleanup work list.
        // The committed removal stays successful if cleanup must wait for restart.
        try? await coordinator.recoverImports()
    }
}
