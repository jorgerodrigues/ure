import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct ChildRemovalTests {
    @Test
    func removedTaskClearsLinksAndCompactsOrderButKeepsParts() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let other = try await JobTaskFixture.job(coordinator)
        let part = try await PartService(coordinator: coordinator).save(
            PartFixture.draft(), for: job.id, editing: nil)
        let tasks = JobTaskService(coordinator: coordinator)
        var draft = JobTaskFixture.draft(.done)
        draft.partIDs = [part.id]
        let removed = try await tasks.save(draft, for: job.id, editing: nil)
        let survivor = try await tasks.save(JobTaskFixture.draft(.toDo), for: job.id, editing: nil)
        let removal = ChildRemovalService(coordinator: coordinator)
        await #expect(throws: RemovalError.scopeMismatch) {
            try await removal.removeTask(removed.id, for: other.id, confirmedPartIDs: [part.id])
        }
        await #expect(throws: RemovalError.changedLinks) {
            try await removal.removeTask(removed.id, for: job.id, confirmedPartIDs: [])
        }
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql:
                    "CREATE TRIGGER failTaskRemoval BEFORE DELETE ON jobTask BEGIN SELECT RAISE(ABORT, 'injected'); END"
            )
        }
        await #expect(throws: DatabaseError.self) {
            try await removal.removeTask(removed.id, for: job.id, confirmedPartIDs: [part.id])
        }
        #expect(
            try await coordinator.read { try TaskPartQueries.linked(to: removed.id, in: $0) }.count
                == 1)
        #expect(
            try await coordinator.read { try JobTaskQueries.fetch(removed.id, in: $0) } == removed)
        try await coordinator.mutate { db, _, _ in
            try db.execute(sql: "DROP TRIGGER failTaskRemoval")
        }
        let remaining = try await removal.removeTask(
            removed.id, for: job.id, confirmedPartIDs: [part.id])
        #expect(remaining.map(\.id) == [survivor.id] && remaining.first?.position == 0)
        #expect(
            try await coordinator.read { try TaskPartQueries.linked(to: removed.id, in: $0) }
                .isEmpty)
        #expect(try await coordinator.read { try PartQueries.fetch(part.id, in: $0) } == part)
        try await coordinator.close()
    }
}

nonisolated struct RemovalFixtureFailure: Error {}
