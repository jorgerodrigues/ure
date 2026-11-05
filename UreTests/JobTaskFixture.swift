import Foundation
import GRDB

@testable import Ure

nonisolated enum JobTaskFixture {
    static func job(_ coordinator: LibraryCoordinator) async throws -> JobRecord {
        let saved = try await WatchService(coordinator: coordinator).make("Omega 0012–Å")
        return try await JobService(coordinator: coordinator).start(
            for: saved.id, title: "Service movement")
    }

    // Makes every insert and update of a table fail, like a full disk, until writes are
    // allowed again.
    static func failWrites(_ coordinator: LibraryCoordinator, on table: String) async throws {
        try await coordinator.mutate { db, _, _ in
            for operation in ["INSERT", "UPDATE"] {
                try db.execute(
                    sql: """
                        CREATE TRIGGER fail_\(table)_\(operation) BEFORE \(operation) ON \(table)
                        BEGIN SELECT RAISE(ABORT, 'fixture disk failure'); END
                        """)
            }
        }
    }

    static func allowWrites(_ coordinator: LibraryCoordinator, on table: String) async throws {
        try await coordinator.mutate { db, _, _ in
            for operation in ["INSERT", "UPDATE"] {
                try db.execute(sql: "DROP TRIGGER fail_\(table)_\(operation)")
            }
        }
    }
}
