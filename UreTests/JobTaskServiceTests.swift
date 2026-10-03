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
    func statusChangesCommitHistoryWithoutChangingJob(from: JobTaskStatus, to: JobTaskStatus)
        async throws
    {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = JobTaskService(coordinator: coordinator)
        let first = try await service.save(JobTaskFixture.draft(from), for: job.id, editing: nil)
        let before = try await coordinator.read(ActivityQueries.fetchAll)
        var edit = JobTaskDraft(task: first)
        edit.status = to
        edit.waitingReason = "Need evidence"
        edit.skippedReason = "Not needed for this repair"
        let next = try await service.save(edit, for: job.id, editing: first.id)
        #expect(next.id == first.id)
        #expect(next.createdAt == first.createdAt)
        #expect(try await coordinator.read(JobQueries.fetchAll) == [job])
        let events = try await coordinator.read(ActivityQueries.fetchAll)
        if from == to {
            #expect(events == before)
        } else {
            let event = try #require(events.last)
            #expect(events.count == before.count + 1)
            #expect(event.kind == .taskStatusChanged)
            #expect(event.jobID == job.id)
            #expect(event.priorValue == .task(JobTaskValue(task: first)))
            #expect(event.nextValue == .task(JobTaskValue(task: next)))
            _ = try await service.save(edit, for: job.id, editing: first.id)
            #expect(try await coordinator.read(ActivityQueries.fetchAll) == events)
        }
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
        #expect(try await coordinator.read(ActivityQueries.fetchAll).isEmpty)
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
    func failedEventRollsBackCompletionReopeningAndNewDoneTask() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = JobTaskService(coordinator: coordinator)
        let todo = try await service.save(JobTaskFixture.draft(.toDo), for: job.id, editing: nil)
        let done = try await service.save(JobTaskFixture.draft(.done), for: job.id, editing: nil)
        let before = try await coordinator.read(ActivityQueries.fetchAll)
        try await JobTaskFixture.failEvents(coordinator)
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
        #expect(try await coordinator.read(ActivityQueries.fetchAll) == before)
        try await coordinator.mutate { db, _, _ in try db.execute(sql: "DROP TRIGGER failTaskEvent")
        }
        _ = try await service.save(JobTaskFixture.draft(.done), for: job.id, editing: todo.id)
        #expect(try await coordinator.read(JobTaskQueries.fetchAll).count == 2)
        #expect(try await coordinator.read(ActivityQueries.fetchAll).count == before.count + 1)
        try await coordinator.close()
    }

    @Test(arguments: [JobStage.completed, .cancelled])
    func closureRequiresExplanationKeepsTasksAndRejectsStaleWrites(stage: JobStage) async throws {
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
        let events = try await coordinator.read(ActivityQueries.fetchAll)
        let jobs = JobService(coordinator: coordinator)
        var closure = JobTransitionDraft(stage: stage)
        closure.outcome = "Movement serviced"
        closure.cancellationReason = "Owner declined further work"
        closure.unfinishedTasksReason = " \n "
        await #expect(throws: JobValidationError.self) {
            try await jobs.transition(job.id, using: closure)
        }
        #expect(try await coordinator.read(JobQueries.fetchAll) == [job])
        #expect(try await coordinator.read(ActivityQueries.fetchAll) == events)
        closure.unfinishedTasksReason = "Owner will arrange the remaining work"
        try await JobTaskFixture.failEvents(coordinator)
        await #expect(throws: DatabaseError.self) {
            try await jobs.transition(job.id, using: closure)
        }
        #expect(try await coordinator.read(JobQueries.fetchAll) == [job])
        try await coordinator.mutate { db, _, _ in try db.execute(sql: "DROP TRIGGER failTaskEvent")
        }
        let closed = try await jobs.transition(job.id, using: closure)
        #expect(closed.unfinishedTasksReason == closure.unfinishedTasksReason)
        let event = try #require(try await coordinator.read(ActivityQueries.fetchAll).last)
        #expect(event.nextValue == .job(JobStageValue(job: closed)))
        #expect(try await coordinator.read(JobTaskQueries.fetchAll) == before)
        let saved = try #require(before.first)
        await #expect(throws: JobError.closedJob) {
            try await tasks.save(JobTaskFixture.draft(.done), for: job.id, editing: saved.id)
        }
        await #expect(throws: JobError.closedJob) {
            try await tasks.save(JobTaskFixture.draft(.toDo), for: job.id, editing: nil)
        }
        let reopened = try await jobs.reopen(job.id, using: JobTransitionDraft(stage: .inProgress))
        #expect(reopened.unfinishedTasksReason == nil)
        #expect(try await coordinator.read(JobTaskQueries.fetchAll) == before)
        _ = try await tasks.save(JobTaskFixture.draft(.done), for: job.id, editing: saved.id)
        try await coordinator.close()
    }

    @Test
    func doneAndSkippedTasksDoNotRequireAnUnfinishedExplanation() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = JobTaskService(coordinator: coordinator)
        for status in [JobTaskStatus.done, .skipped] {
            _ = try await service.save(JobTaskFixture.draft(status), for: job.id, editing: nil)
        }
        var closure = JobTransitionDraft(stage: .completed)
        closure.outcome = "Finished"
        let closed = try await JobService(coordinator: coordinator).transition(
            job.id, using: closure)
        #expect(closed.unfinishedTasksReason == nil)
        try await coordinator.close()
    }

    @Test
    func forwardMigrationPreservesCoversFilesNotesAndOldHistory() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        let before = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let source = try fixture.source(type: .png)
        let result = try #require(
            await PhotoService(coordinator: coordinator).importFiles(
                [source], for: .job(job.id)
            ).first)
        let photo = try result.outcome.get()
        _ = try await PhotoService(coordinator: coordinator).setCover(photo.id, for: job.watchID)
        var noteDraft = NoteDraft()
        noteDraft.title = "Keep this finding"
        let note = try await NoteService(coordinator: coordinator).save(
            noteDraft, for: .job(job.id), editing: nil)
        let link = try await ReferenceService(coordinator: coordinator).save(
            ReferenceFixture.draft, for: .job(job.id), editing: nil)
        _ = try await JobService(coordinator: coordinator).transition(
            job.id, using: JobTransitionDraft(stage: .inProgress))
        let watches = try await coordinator.read(WatchQueries.fetchAll)
        let jobs = try await coordinator.read(JobQueries.fetchAll)
        let events = try await coordinator.read(ActivityQueries.fetchAll)
        let bytes = try Data(contentsOf: try await coordinator.originalURL(for: photo.asset.id))
        try await coordinator.mutate { db, _, _ in
            try JobTaskMigrationFixture.removeTasks(in: db)
            try db.execute(
                sql:
                    "UPDATE activityEvent SET priorValue = json_remove(priorValue, '$.job._0.unfinishedTasksReason'), nextValue = json_remove(nextValue, '$.job._0.unfinishedTasksReason')"
            )
        }
        try await coordinator.close()
        let reopened = LibraryCoordinator(root: fixture.root)
        let after = try await reopened.open()
        #expect(after.generationID != before.generationID)
        #expect(after.manifest == before.manifest)
        #expect(try await reopened.read(WatchQueries.fetchAll) == watches)
        #expect(try await reopened.read(JobQueries.fetchAll) == jobs)
        #expect(try await reopened.read(ActivityQueries.fetchAll) == events)
        #expect(try await reopened.read(NoteQueries.fetchAll) == [note])
        #expect(try await reopened.read(LibraryItemQueries.fetchAll).contains(link))
        #expect(try await reopened.read(PhotoQueries.fetchAll) == [photo])
        #expect(try Data(contentsOf: try await reopened.originalURL(for: photo.asset.id)) == bytes)
        #expect(try await reopened.read(JobTaskQueries.fetchAll).isEmpty)
        var created = JobTaskFixture.draft(.done)
        created.title = "Completed after migration"
        _ = try await JobTaskService(coordinator: reopened).save(created, for: job.id, editing: nil)
        let updatedEvents = try await reopened.read(ActivityQueries.fetchAll)
        #expect(updatedEvents.map(\.ordering) == [1, 2])
        #expect(updatedEvents.last?.kind == .taskStatusChanged)
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
        var watch = WatchDraft()
        watch.name = "Omega 0012–Å"
        let saved = try await WatchService(coordinator: coordinator).save(watch, editing: nil)
        var job = JobDraft()
        job.title = "Service movement"
        return try await JobService(coordinator: coordinator).save(job, for: saved.id, editing: nil)
    }

    static func draft(_ status: JobTaskStatus) -> JobTaskDraft {
        var draft = JobTaskDraft()
        draft.title = "Inspect escapement"
        draft.status = status
        draft.waitingReason = "Need evidence"
        draft.skippedReason = "Not needed for this repair"
        return draft
    }

    static func failEvents(_ coordinator: LibraryCoordinator) async throws {
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql:
                    "CREATE TRIGGER failTaskEvent BEFORE INSERT ON activityEvent BEGIN SELECT RAISE(ABORT, 'fixture disk failure'); END"
            )
        }
    }
}
