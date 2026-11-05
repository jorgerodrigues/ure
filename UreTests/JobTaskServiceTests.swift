import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct JobTaskServiceTests {
    @Test(arguments: JobTaskStatus.allCases)
    func statusesAndOptionalFieldsSurviveRestart(status: JobTaskStatus) async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = Date(timeIntervalSinceReferenceDate: 800_000_000.0000001)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { clock }))
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        var draft = JobTaskFixture.draft(status)
        draft.title = "  Inspect Å時計  "
        draft.detail = "Check endshake\nKeep 0012–Å/3"
        draft.groupLabel = "  Inspection  "
        let saved = try await JobTaskService(coordinator: coordinator).save(
            draft, for: job.id, editing: nil)
        #expect(saved.title == "Inspect Å時計")
        #expect(saved.detail == draft.detail)
        #expect(saved.groupLabel == "Inspection")
        #expect(saved.status == status)
        #expect(saved.waitingReason == (status == .waiting ? "Need evidence" : nil))
        #expect(saved.skippedReason == (status == .skipped ? "Not needed for this repair" : nil))
        #expect(saved.createdAt == Date(timeIntervalSince1970: clock.timeIntervalSince1970))
        #expect(saved.updatedAt == saved.createdAt)
        #expect(try await coordinator.read(JobQueries.fetchAll) == [job])
        try await coordinator.close()
        let reopened = fixture.coordinator()
        _ = try await reopened.open()
        #expect(try await reopened.read(JobTaskQueries.fetchAll) == [saved])
        try await reopened.close()
    }

    @Test(arguments: JobTaskStatus.allCases, JobTaskStatus.allCases)
    func statusChangesSaveWithoutChangingTheJob(from: JobTaskStatus, to: JobTaskStatus)
        async throws
    {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = JobTaskService(coordinator: coordinator)
        let first = try await service.save(JobTaskFixture.draft(from), for: job.id, editing: nil)
        var edit = JobTaskDraft(task: first)
        edit.status = to
        edit.waitingReason = "Need evidence"
        edit.skippedReason = "Not needed for this repair"
        let next = try await service.save(edit, for: job.id, editing: first.id)
        #expect(next.id == first.id && next.status == to)
        #expect(next.createdAt == first.createdAt)
        #expect(try await coordinator.read(JobQueries.fetchAll) == [job])
        #expect(try await service.save(edit, for: job.id, editing: first.id) == next)
        #expect(try await coordinator.read(JobTaskQueries.fetchAll) == [next])
        try await coordinator.close()
    }

    @Test
    func validationAndDatabaseConstraintsRejectMissingReasonsAndOwners() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = JobTaskService(coordinator: coordinator)
        for status in [JobTaskStatus.waiting, .skipped] {
            var draft = JobTaskFixture.draft(status)
            draft.waitingReason = " \n\t "
            draft.skippedReason = " \n\t "
            await #expect(throws: JobTaskValidationError.self) {
                try await service.save(draft, for: job.id, editing: nil)
            }
        }
        await #expect(throws: JobTaskValidationError.self) {
            try await service.save(JobTaskDraft(), for: job.id, editing: nil)
        }
        #expect(try await coordinator.read(JobTaskQueries.fetchAll).isEmpty)
        let saved = try await service.save(JobTaskFixture.draft(.toDo), for: job.id, editing: nil)
        for sql in [
            "UPDATE jobTask SET title = ''", "UPDATE jobTask SET status = 'Unknown'",
            "UPDATE jobTask SET status = 'Skipped'",
            "UPDATE jobTask SET jobID = 'MISSING'",
        ] {
            await #expect(throws: DatabaseError.self) {
                try await coordinator.mutate { db, _, _ in try db.execute(sql: sql) }
            }
        }
        let other = try await JobTaskFixture.job(coordinator)
        await #expect(throws: JobTaskError.jobMismatch) {
            try await service.save(JobTaskFixture.draft(.doing), for: other.id, editing: saved.id)
        }
        await #expect(throws: JobTaskError.missingRecord) {
            try await service.save(JobTaskFixture.draft(.doing), for: job.id, editing: UUID())
        }
        await #expect(throws: JobError.missingRecord) {
            try await service.save(JobTaskFixture.draft(.doing), for: UUID(), editing: nil)
        }
        #expect(try await coordinator.read(JobTaskQueries.fetchAll) == [saved])
        try await coordinator.close()
    }

    @Test
    func failedWritesLeaveTheSavedTasks() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = JobTaskService(coordinator: coordinator)
        let todo = try await service.save(JobTaskFixture.draft(.toDo), for: job.id, editing: nil)
        let done = try await service.save(JobTaskFixture.draft(.done), for: job.id, editing: nil)
        try await JobTaskFixture.failWrites(coordinator, on: "jobTask")
        for (id, status) in [(todo.id, JobTaskStatus.done), (done.id, .doing)] {
            await #expect(throws: DatabaseError.self) {
                try await service.save(JobTaskFixture.draft(status), for: job.id, editing: id)
            }
        }
        await #expect(throws: DatabaseError.self) {
            try await service.save(JobTaskFixture.draft(.done), for: job.id, editing: nil)
        }
        let tasks = try await coordinator.read(JobTaskQueries.fetchAll)
        #expect(tasks.count == 2 && tasks.contains(todo) && tasks.contains(done))
        try await JobTaskFixture.allowWrites(coordinator, on: "jobTask")
        _ = try await service.save(JobTaskFixture.draft(.done), for: job.id, editing: todo.id)
        #expect(try await coordinator.read(JobTaskQueries.fetchAll).count == 2)
        try await coordinator.close()
    }

    @Test(arguments: [JobStage.waiting, .done])
    func aJobInAnyStateKeepsItsTasksAndTakesChanges(stage: JobStage) async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let tasks = JobTaskService(coordinator: coordinator)
        for status in JobTaskStatus.allCases {
            _ = try await tasks.save(JobTaskFixture.draft(status), for: job.id, editing: nil)
        }
        let before = try await coordinator.read(JobTaskQueries.fetchAll)
        let jobs = JobService(coordinator: coordinator)
        let changed = try await jobs.setStage(job.id, to: stage).job
        #expect(changed.stage == stage)
        #expect(try await coordinator.read(JobTaskQueries.fetchAll) == before)
        let saved = try #require(before.first { $0.status == .toDo })
        let ticked = try await tasks.save(
            JobTaskFixture.draft(.done), for: job.id, editing: saved.id)
        #expect(ticked.status == .done)
        let added = try await tasks.save(JobTaskFixture.draft(.toDo), for: job.id, editing: nil)
        #expect(try await coordinator.read(JobTaskQueries.fetchAll).count == before.count + 1)
        _ = try await jobs.setStage(job.id, to: .inProgress)
        #expect(try await coordinator.read { try JobTaskQueries.fetch(added.id, in: $0) } == added)
        try await coordinator.close()
    }

    @Test
    func forwardMigrationPreservesCoversFilesAndNotes() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        let before = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let source = try fixture.source(type: .png)
        let photo = try await MaterialFixture.file(source, for: .job(job.id), in: coordinator)
        try await MaterialService(coordinator: coordinator).setCover(photo.id, for: job.watchID)
        try await RecordNotesService(coordinator: coordinator).save(
            "Keep this finding", for: .job(job.id))
        let link = try await MaterialFixture.link(
            titled: "Technical sheet", for: .job(job.id), in: coordinator)
        let watches = try await coordinator.read(WatchQueries.fetchAll)
        let jobs = try await coordinator.read(JobQueries.fetchAll)
        let asset = try #require(photo.asset)
        let bytes = try Data(contentsOf: try await coordinator.originalURL(for: asset.id))
        try await coordinator.mutate { db, _, _ in try JobTaskMigrationFixture.removeTasks(in: db) }
        try await coordinator.close()
        let reopened = LibraryCoordinator(root: fixture.root)
        let after = try await reopened.open()
        #expect(after.generationID != before.generationID)
        #expect(after.manifest == before.manifest)
        #expect(try await reopened.read(WatchQueries.fetchAll) == watches)
        #expect(try await reopened.read(JobQueries.fetchAll) == jobs)
        #expect(
            try await RecordNotesService(coordinator: reopened).text(for: .job(job.id))
                .hasSuffix(" · Observation · Notes\nKeep this finding"))
        #expect(try await reopened.read(LibraryItemQueries.fetchAll).contains(link))
        #expect(try await reopened.read(MaterialQueries.fetchAll).contains(photo))
        #expect(try Data(contentsOf: try await reopened.originalURL(for: asset.id)) == bytes)
        #expect(try await reopened.read(JobTaskQueries.fetchAll).isEmpty)
        var created = JobTaskFixture.draft(.done)
        created.title = "Completed after migration"
        _ = try await JobTaskService(coordinator: reopened).save(created, for: job.id, editing: nil)
        #expect(try await reopened.read(JobTaskQueries.fetchAll).map(\.title) == [created.title])
        try await reopened.close()
    }
}

nonisolated enum JobTaskMigrationFixture {
    static func removeTasks(in db: Database) throws {
        try PartMigrationFixture.removeParts(in: db)
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v12-task-order'")
        try db.drop(table: "jobTask")
        try db.execute(sql: "ALTER TABLE job DROP COLUMN unfinishedTasksReason")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v11-job-tasks'")
        try db.execute(
            sql: """
                CREATE TABLE activityEvent_old (
                    id TEXT PRIMARY KEY, jobID TEXT NOT NULL REFERENCES job(id),
                    kind TEXT NOT NULL CHECK(kind IN ('Job stage changed', 'Watch condition changed')),
                    occurredAt DOUBLE NOT NULL, ordering INTEGER NOT NULL UNIQUE CHECK(ordering > 0),
                    priorValue TEXT NOT NULL CHECK(json_valid(priorValue)),
                    nextValue TEXT NOT NULL CHECK(json_valid(nextValue)))
                """)
        try db.execute(sql: "INSERT INTO activityEvent_old SELECT * FROM activityEvent")
        try db.drop(table: "activityEvent")
        try db.rename(table: "activityEvent_old", to: "activityEvent")
        try db.create(
            index: "activityEvent_jobID_ordering", on: "activityEvent",
            columns: ["jobID", "ordering"])
    }
}

nonisolated enum JobTaskFixture {
    static func job(_ coordinator: LibraryCoordinator) async throws -> JobRecord {
        let saved = try await WatchService(coordinator: coordinator).make("Omega 0012–Å")
        return try await JobService(coordinator: coordinator).start(
            for: saved.id, title: "Service movement")
    }

    static func draft(_ status: JobTaskStatus) -> JobTaskDraft {
        var draft = JobTaskDraft()
        draft.title = "Inspect escapement"
        draft.status = status
        draft.waitingReason = "Need evidence"
        draft.skippedReason = "Not needed for this repair"
        return draft
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
