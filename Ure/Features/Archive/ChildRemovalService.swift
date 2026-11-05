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
}
