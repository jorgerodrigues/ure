import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct JobTaskOrderingTests {
    @Test
    func movesPersistWithoutChangingContentStatusOrHistory() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let other = try await JobTaskFixture.job(coordinator)
        let service = JobTaskService(coordinator: coordinator)
        let a = try await service.save(JobTaskFixture.draft(.waiting), for: job.id, editing: nil)
        let b = try await service.save(JobTaskFixture.draft(.done), for: job.id, editing: nil)
        let c = try await service.save(JobTaskFixture.draft(.skipped), for: job.id, editing: nil)
        let d = try await service.save(JobTaskFixture.draft(.doing), for: other.id, editing: nil)
        let positions = [a.position, b.position, c.position, d.position]
        #expect(positions == [0, 1, 2, 0])
        let events = try await coordinator.read(ActivityQueries.fetchAll)
        #expect(try await service.move(c.id, for: job.id, to: .up).map(\.id) == [a.id, c.id, b.id])
        #expect(
            try await service.move(a.id, for: job.id, to: .end).map(\.id) == [c.id, b.id, a.id])
        #expect(
            try await service.move(b.id, for: job.id, to: .before(c.id)).map(\.id) == [
                b.id, c.id, a.id,
            ])
        #expect(
            try await service.move(b.id, for: job.id, to: .down).map(\.id) == [c.id, b.id, a.id])
        let final = try await service.move(a.id, for: job.id, to: .before(c.id))
        #expect(final.map(\.id) == [a.id, c.id, b.id])
        #expect(final.map(\.position) == [0, 1, 2])
        for original in [a, b, c] {
            let saved = try #require(final.first { $0.id == original.id })
            #expect(JobTaskDraft(task: saved) == JobTaskDraft(task: original))
            #expect(saved.createdAt == original.createdAt && saved.updatedAt == original.updatedAt)
        }
        #expect(
            try await coordinator.read { try JobTaskQueries.ordered(for: other.id, in: $0) } == [d])
        #expect(try await coordinator.read(ActivityQueries.fetchAll) == events)
        #expect(
            try await coordinator.read { try JobTaskQueries.unfinished(for: job.id, in: $0) }.map(
                \.id) == [a.id])
        var staleDraft = JobTaskDraft(task: b)
        staleDraft.detail = "Edit from before the move"
        let edited = try await service.save(staleDraft, for: job.id, editing: b.id)
        #expect(edited.position == 2)
        let appended = try await service.save(
            JobTaskFixture.draft(.toDo), for: job.id, editing: nil)
        #expect(appended.position == 3)
        let saved = try await coordinator.read { try JobTaskQueries.ordered(for: job.id, in: $0) }
        try await coordinator.close()
        let reopened = fixture.coordinator()
        _ = try await reopened.open()
        #expect(
            try await reopened.read { try JobTaskQueries.ordered(for: job.id, in: $0) } == saved)
        try await reopened.close()
    }

    @Test
    func failedWriteRollsBackEveryPositionAndCanBeRetried() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = JobTaskService(coordinator: coordinator)
        let a = try await service.save(JobTaskFixture.draft(.doing), for: job.id, editing: nil)
        let b = try await service.save(JobTaskFixture.draft(.waiting), for: job.id, editing: nil)
        let c = try await service.save(JobTaskFixture.draft(.done), for: job.id, editing: nil)
        let events = try await coordinator.read(ActivityQueries.fetchAll)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: """
                    CREATE TRIGGER failTaskOrder BEFORE UPDATE OF position ON jobTask
                    WHEN NEW.position = 1
                    BEGIN SELECT RAISE(ABORT, 'fixture disk failure'); END
                    """)
        }
        await #expect(throws: DatabaseError.self) {
            try await service.move(c.id, for: job.id, to: .before(a.id))
        }
        #expect(
            try await coordinator.read { try JobTaskQueries.ordered(for: job.id, in: $0) } == [
                a, b, c,
            ])
        #expect(try await coordinator.read(ActivityQueries.fetchAll) == events)
        try await coordinator.mutate { db, _, _ in try db.execute(sql: "DROP TRIGGER failTaskOrder")
        }
        #expect(
            try await service.move(c.id, for: job.id, to: .before(a.id)).map(\.id) == [
                c.id, a.id, b.id,
            ])
        try await coordinator.close()
    }

    @Test(arguments: [JobStage.completed, .cancelled])
    func closedJobsRejectMovesAndKeepHonestProgress(stage: JobStage) async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = JobTaskService(coordinator: coordinator)
        let a = try await service.save(JobTaskFixture.draft(.done), for: job.id, editing: nil)
        _ = try await service.save(JobTaskFixture.draft(.toDo), for: job.id, editing: nil)
        _ = try await service.save(JobTaskFixture.draft(.skipped), for: job.id, editing: nil)
        var closure = JobTransitionDraft(stage: stage)
        closure.outcome = "Repair retained"
        closure.cancellationReason = "Owner declined"
        closure.unfinishedTasksReason = "Owner will arrange final testing"
        _ = try await JobService(coordinator: coordinator).transition(job.id, using: closure)
        let before = try await coordinator.read(JobTaskQueries.fetchAll)
        let events = try await coordinator.read(ActivityQueries.fetchAll)
        await #expect(throws: JobError.closedJob) {
            try await service.move(a.id, for: job.id, to: .down)
        }
        await #expect(throws: JobError.closedJob) {
            try await service.move(a.id, for: job.id, to: .up)
        }
        #expect(try await coordinator.read(JobTaskQueries.fetchAll) == before)
        #expect(try await coordinator.read(ActivityQueries.fetchAll) == events)
        #expect(JobTaskProgress(tasks: before).percentage == 50)
        #expect(JobTaskProgress(tasks: before).skippedCount == 1)
        try await coordinator.close()
    }

    @Test
    func boundariesAndWrongJobMovesDoNotWrite() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let other = try await JobTaskFixture.job(coordinator)
        let service = JobTaskService(coordinator: coordinator)
        let a = try await service.save(JobTaskFixture.draft(.toDo), for: job.id, editing: nil)
        let b = try await service.save(JobTaskFixture.draft(.doing), for: other.id, editing: nil)
        for move in [JobTaskMove.up, .down, .end, .before(a.id)] {
            #expect(try await service.move(a.id, for: job.id, to: move) == [a])
        }
        await #expect(throws: JobTaskError.jobMismatch) {
            try await service.move(b.id, for: job.id, to: .up)
        }
        await #expect(throws: JobTaskError.jobMismatch) {
            try await service.move(a.id, for: job.id, to: .before(b.id))
        }
        await #expect(throws: JobTaskError.missingRecord) {
            try await service.move(UUID(), for: job.id, to: .end)
        }
        await #expect(throws: JobTaskError.missingRecord) {
            try await service.move(a.id, for: job.id, to: .before(UUID()))
        }
        await #expect(throws: DatabaseError.self) {
            try await coordinator.mutate { db, _, _ in
                try db.execute(sql: "UPDATE jobTask SET position = -1")
            }
        }
        #expect(try await coordinator.read(JobTaskQueries.fetchAll).contains(a))
        #expect(try await coordinator.read(JobTaskQueries.fetchAll).contains(b))
        try await coordinator.close()
    }

    @Test
    func migrationSeedsEachJobFromOldDeterministicOrder() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        let before = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let other = try await JobTaskFixture.job(coordinator)
        let service = JobTaskService(coordinator: coordinator)
        for jobID in [job.id, other.id] {
            for status in JobTaskStatus.allCases {
                _ = try await service.save(JobTaskFixture.draft(status), for: jobID, editing: nil)
            }
        }
        try await coordinator.mutate { db, originals, _ in
            try db.execute(sql: "UPDATE jobTask SET createdAt = 1000")
            try Data("Original bytes".utf8).write(to: originals.appending(path: "evidence.bin"))
        }
        let records = try await coordinator.read(JobTaskQueries.fetchAll)
        let events = try await coordinator.read(ActivityQueries.fetchAll)
        try await coordinator.mutate { db, _, _ in
            try PartMigrationFixture.removeParts(in: db)
            try db.drop(index: "jobTask_jobID_position")
            try db.execute(sql: "ALTER TABLE jobTask DROP COLUMN position")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v12-task-order'")
        }
        try await coordinator.close()
        let upgraded = fixture.coordinator()
        let after = try await upgraded.open()
        #expect(after.generationID != before.generationID && after.manifest == before.manifest)
        for jobID in [job.id, other.id] {
            let saved = try await upgraded.read { try JobTaskQueries.ordered(for: jobID, in: $0) }
            let old = records.filter { $0.jobID == jobID }.sorted {
                $0.id.uuidString < $1.id.uuidString
            }
            #expect(saved.map(\.id) == old.map(\.id))
            #expect(saved.map(\.position) == Array(0..<saved.count))
            #expect(saved.map { JobTaskDraft(task: $0) } == old.map { JobTaskDraft(task: $0) })
            #expect(saved.map(\.createdAt) == old.map(\.createdAt))
            #expect(saved.map(\.updatedAt) == old.map(\.updatedAt))
        }
        #expect(try await upgraded.read(ActivityQueries.fetchAll) == events)
        #expect(try await upgraded.read(JobQueries.fetchAll).contains(job))
        #expect(try await upgraded.read(JobQueries.fetchAll).contains(other))
        #expect(
            try Data(
                contentsOf: LibraryFiles.generation(after.generationID, in: fixture.root).appending(
                    path: "originals/evidence.bin")) == Data("Original bytes".utf8))
        try await upgraded.close()
    }
}
