import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct TaskPartServiceTests {
    @Test
    func severalLinksSurviveRestartAndProcurementNeverChangesTasksOrJobs() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = Date(timeIntervalSince1970: 1_700_000_000.125)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { clock }))
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let parts = PartService(coordinator: coordinator)
        let first = try await parts.save(PartFixture.draft(), for: job.id, editing: nil)
        let second = try await parts.save(PartFixture.draft(), for: job.id, editing: nil)
        var draft = JobTaskFixture.draft(.waiting)
        draft.waitingReason = ""
        draft.partIDs = [first.id, second.id]
        let tasks = JobTaskService(coordinator: coordinator)
        let waiting = try await tasks.save(draft, for: job.id, editing: nil)
        #expect(waiting.waitingReason == nil)
        #expect(
            try await TaskPartFixture.availability(waiting.id, in: coordinator) == .waitingForParts)
        let ordered = try await TaskPartFixture.change(first, to: .ordered, using: parts)
        #expect(
            try await TaskPartFixture.availability(waiting.id, in: coordinator) == .waitingForParts)
        let arrived = try await TaskPartFixture.change(ordered, to: .arrived, using: parts)
        #expect(
            try await TaskPartFixture.availability(waiting.id, in: coordinator) == .waitingForParts)
        let installed = try await TaskPartFixture.change(arrived, to: .installed, using: parts)
        let otherArrived = try await TaskPartFixture.change(second, to: .arrived, using: parts)
        #expect(
            try await TaskPartFixture.availability(waiting.id, in: coordinator) == .partsAvailable)
        #expect(try await coordinator.read(JobTaskQueries.fetchAll) == [waiting])
        #expect(try await coordinator.read(JobQueries.fetchAll) == [job])
        #expect(try await tasks.save(draft, for: job.id, editing: waiting.id) == waiting)
        let cancelled = try await TaskPartFixture.change(otherArrived, to: .cancelled, using: parts)
        #expect(try await TaskPartFixture.availability(waiting.id, in: coordinator) == .needsReview)
        #expect(try await tasks.save(draft, for: job.id, editing: waiting.id) == waiting)
        let links = try await coordinator.read(TaskPartQueries.fetchAll)
        #expect(Set(links.map(\.partID)) == [first.id, second.id])
        #expect(links.allSatisfy { $0.taskID == waiting.id })
        let events = try await coordinator.read(ActivityQueries.fetchAll)
        #expect(events.allSatisfy { $0.kind == .partStatusChanged })
        try await coordinator.close()
        let reopened = fixture.coordinator()
        _ = try await reopened.open()
        #expect(try await reopened.read(TaskPartQueries.fetchAll) == links)
        #expect(try await reopened.read(JobTaskQueries.fetchAll) == [waiting])
        #expect(try await reopened.read(JobQueries.fetchAll) == [job])
        #expect(try await reopened.read(ActivityQueries.fetchAll) == events)
        let savedParts = try await reopened.read(PartQueries.fetchAll)
        #expect(savedParts.contains(installed) && savedParts.contains(cancelled))
        #expect(try await TaskPartFixture.availability(waiting.id, in: reopened) == .needsReview)
        try await reopened.close()
    }

    @Test
    func selectionRejectsForeignMissingAndAvailableWaitingReasons() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let other = try await JobTaskFixture.job(coordinator)
        let parts = PartService(coordinator: coordinator)
        let foreign = try await parts.save(PartFixture.draft(), for: other.id, editing: nil)
        let service = JobTaskService(coordinator: coordinator)
        var draft = JobTaskFixture.draft(.waiting)
        draft.waitingReason = ""
        draft.partIDs = [foreign.id]
        await #expect(throws: JobTaskError.partJobMismatch) {
            try await service.save(draft, for: job.id, editing: nil)
        }
        draft.partIDs = [UUID()]
        await #expect(throws: JobTaskError.missingPart) {
            try await service.save(draft, for: job.id, editing: nil)
        }
        var onHandDraft = PartFixture.draft()
        onHandDraft.status = .arrived
        var part = try await parts.save(onHandDraft, for: job.id, editing: nil)
        for status in [PartStatus.arrived, .installed, .cancelled] {
            if status != .arrived {
                part = try await TaskPartFixture.change(part, to: status, using: parts)
            }
            draft.partIDs = [part.id]
            await #expect(throws: JobTaskValidationError.self) {
                try await service.save(draft, for: job.id, editing: nil)
            }
        }
        let needed = try await parts.save(PartFixture.draft(), for: job.id, editing: nil)
        draft.status = .skipped
        draft.skippedReason = ""
        draft.partIDs = [needed.id]
        await #expect(throws: JobTaskValidationError.self) {
            try await service.save(draft, for: job.id, editing: nil)
        }
        #expect(try await coordinator.read(JobTaskQueries.fetchAll).isEmpty)
        #expect(try await coordinator.read(TaskPartQueries.fetchAll).isEmpty)
        try await coordinator.close()
    }

    @Test
    func unlinkingLastUnresolvedPartRequiresTextOrAnotherStatus() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let parts = PartService(coordinator: coordinator)
        let first = try await parts.save(PartFixture.draft(), for: job.id, editing: nil)
        let second = try await parts.save(PartFixture.draft(), for: job.id, editing: nil)
        var onHand = PartFixture.draft()
        onHand.status = .arrived
        let arrived = try await parts.save(onHand, for: job.id, editing: nil)
        let service = JobTaskService(coordinator: coordinator)
        var draft = JobTaskFixture.draft(.waiting)
        draft.waitingReason = ""
        draft.partIDs = [first.id, second.id, arrived.id]
        let waiting = try await service.save(draft, for: job.id, editing: nil)
        draft.partIDs.remove(first.id)
        let reduced = try await service.save(draft, for: job.id, editing: waiting.id)
        draft.partIDs.remove(second.id)
        let links = try await coordinator.read(TaskPartQueries.fetchAll)
        await #expect(throws: JobTaskValidationError.self) {
            try await service.save(draft, for: job.id, editing: waiting.id)
        }
        #expect(try await coordinator.read(JobTaskQueries.fetchAll) == [reduced])
        #expect(try await coordinator.read(TaskPartQueries.fetchAll) == links)
        draft.waitingReason = "Waiting for service information"
        let explained = try await service.save(draft, for: job.id, editing: waiting.id)
        #expect(explained.waitingReason == draft.waitingReason)
        draft.partIDs = []
        draft.status = .doing
        let resumed = try await service.save(draft, for: job.id, editing: waiting.id)
        #expect(resumed.status == .doing && resumed.waitingReason == nil)
        #expect(try await coordinator.read(TaskPartQueries.fetchAll).isEmpty)
        #expect(try await TaskPartFixture.availability(waiting.id, in: coordinator) == nil)
        #expect(try await coordinator.read(JobQueries.fetchAll) == [job])
        try await coordinator.close()
    }

    @Test
    func failedLinkAndEventWritesRollBackAndClosedJobsRejectChanges() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let parts = PartService(coordinator: coordinator)
        let first = try await parts.save(PartFixture.draft(), for: job.id, editing: nil)
        let second = try await parts.save(PartFixture.draft(), for: job.id, editing: nil)
        let service = JobTaskService(coordinator: coordinator)
        var draft = JobTaskFixture.draft(.waiting)
        draft.waitingReason = ""
        draft.partIDs = [first.id]
        let waiting = try await service.save(draft, for: job.id, editing: nil)
        let links = try await coordinator.read(TaskPartQueries.fetchAll)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql:
                    "CREATE TRIGGER failTaskPart BEFORE INSERT ON taskPart BEGIN SELECT RAISE(ABORT, 'fixture disk failure'); END"
            )
        }
        draft.title = "Keep prior saved title"
        draft.partIDs = [second.id]
        await #expect(throws: DatabaseError.self) {
            try await service.save(draft, for: job.id, editing: waiting.id)
        }
        await #expect(throws: DatabaseError.self) {
            try await service.save(draft, for: job.id, editing: nil)
        }
        #expect(try await coordinator.read(JobTaskQueries.fetchAll) == [waiting])
        #expect(try await coordinator.read(TaskPartQueries.fetchAll) == links)
        try await coordinator.mutate { db, _, _ in try db.execute(sql: "DROP TRIGGER failTaskPart")
        }
        try await JobTaskFixture.failEvents(coordinator)
        draft.status = .done
        await #expect(throws: DatabaseError.self) {
            try await service.save(draft, for: job.id, editing: waiting.id)
        }
        #expect(try await coordinator.read(JobTaskQueries.fetchAll) == [waiting])
        #expect(try await coordinator.read(TaskPartQueries.fetchAll) == links)
        try await coordinator.mutate { db, _, _ in try db.execute(sql: "DROP TRIGGER failTaskEvent")
        }
        for link in [
            links[0], TaskPart(taskID: waiting.id, partID: UUID()),
            TaskPart(taskID: UUID(), partID: first.id),
        ] {
            await #expect(throws: DatabaseError.self) {
                try await coordinator.mutate { db, _, _ in try link.insert(db) }
            }
        }
        var closure = JobTransitionDraft(stage: .completed)
        closure.outcome = "Owner collected watch"
        closure.unfinishedTasksReason = "Owner will arrange service"
        closure.unfinishedPartsReason = "Parts no longer required by owner"
        _ = try await JobService(coordinator: coordinator).transition(job.id, using: closure)
        await #expect(throws: JobError.closedJob) {
            try await service.save(draft, for: job.id, editing: waiting.id)
        }
        #expect(try await coordinator.read(JobTaskQueries.fetchAll) == [waiting])
        #expect(try await coordinator.read(TaskPartQueries.fetchAll) == links)
        try await coordinator.close()
    }

    @Test
    func forwardMigrationPreservesTasksProcurementHistoryCoversAndOriginalBytes() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        let before = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let taskService = JobTaskService(coordinator: coordinator)
        let done = try await taskService.save(
            JobTaskFixture.draft(.done), for: job.id, editing: nil)
        let waiting = try await taskService.save(
            JobTaskFixture.draft(.waiting), for: job.id, editing: nil)
        let tasks = try await taskService.move(waiting.id, for: job.id, to: .up)
        var partDraft = PartFixture.draft()
        var supplier = PartLinkDraft(url: "https://example.org/0012-A")
        supplier.supplierName = "Supplier Å時計"
        supplier.price = "0012.3400"
        supplier.currency = "DKK"
        partDraft.links = [supplier]
        partDraft.selectedLinkID = supplier.id
        let parts = PartService(coordinator: coordinator)
        let needed = try await parts.save(partDraft, for: job.id, editing: nil)
        let ordered = try await TaskPartFixture.change(needed, to: .ordered, using: parts)
        let photos = PhotoService(coordinator: coordinator)
        let source = try fixture.source(type: .png)
        let bytes = try Data(contentsOf: source)
        let photo = try await photos.importFiles([source], for: .job(job.id))[0].outcome.get()
        let watch = try await photos.setCover(photo.id, for: job.watchID)
        let events = try await coordinator.read(ActivityQueries.fetchAll)
        try await coordinator.mutate { db, _, _ in try TaskPartMigrationFixture.removeLinks(in: db)
        }
        try await coordinator.close()
        let reopened = LibraryCoordinator(root: fixture.root)
        let after = try await reopened.open()
        #expect(after.generationID != before.generationID && after.manifest == before.manifest)
        #expect(try await reopened.read(JobTaskQueries.fetchAll) == tasks)
        #expect(try await reopened.read(PartQueries.fetchAll) == [ordered])
        #expect(try await reopened.read(ActivityQueries.fetchAll) == events)
        #expect(try await reopened.read(JobQueries.fetchAll) == [job])
        #expect(try await reopened.read(WatchQueries.fetchAll) == [watch])
        #expect(try await reopened.read(PhotoQueries.fetchAll) == [photo])
        #expect(try Data(contentsOf: await reopened.originalURL(for: photo.asset.id)) == bytes)
        #expect(try await reopened.read(TaskPartQueries.fetchAll).isEmpty)
        var draft = JobTaskDraft(task: done)
        draft.status = .waiting
        draft.partIDs = [ordered.id]
        _ = try await JobTaskService(coordinator: reopened).save(
            draft, for: job.id, editing: done.id)
        #expect(try await TaskPartFixture.availability(done.id, in: reopened) == .waitingForParts)
        try await reopened.close()
    }
}

nonisolated enum TaskPartFixture {
    static func availability(_ taskID: UUID, in coordinator: LibraryCoordinator) async throws
        -> TaskPartAvailability?
    {
        let snapshot = try await coordinator.read(TaskPartQueries.snapshot)
        let ids = Set(snapshot.links.filter { $0.taskID == taskID }.map(\.partID))
        return TaskPartAvailability.label(for: snapshot.parts.filter { ids.contains($0.id) })
    }

    static func change(_ part: PartRequirement, to status: PartStatus, using service: PartService)
        async throws -> PartRequirement
    {
        var draft = PartDraft(part: part)
        draft.status = status
        draft.statusReason = "Corrected procurement record"
        draft.confirmsOnHand = true
        return try await service.save(draft, for: part.record.jobID, editing: part.id)
    }
}

nonisolated enum TaskPartMigrationFixture {
    static func removeLinks(in db: Database) throws {
        try db.drop(table: "taskPart")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v16-task-parts'")
        try db.execute(
            sql: """
                CREATE TABLE jobTask_old (
                    id TEXT PRIMARY KEY, jobID TEXT NOT NULL REFERENCES job(id) ON DELETE RESTRICT,
                    title TEXT NOT NULL CHECK(length(trim(title)) > 0),
                    detail TEXT, groupLabel TEXT, waitingReason TEXT, skippedReason TEXT,
                    status TEXT NOT NULL CHECK(status IN ('To do', 'Doing', 'Waiting', 'Done', 'Skipped')),
                    createdAt DOUBLE NOT NULL, updatedAt DOUBLE NOT NULL,
                    position INTEGER NOT NULL DEFAULT 0 CHECK(position >= 0),
                    CHECK(status != 'Waiting' OR (waitingReason IS NOT NULL AND length(trim(waitingReason)) > 0)),
                    CHECK(status != 'Skipped' OR (skippedReason IS NOT NULL AND length(trim(skippedReason)) > 0)))
                """)
        try db.execute(sql: "INSERT INTO jobTask_old SELECT * FROM jobTask")
        try db.drop(table: "jobTask")
        try db.rename(table: "jobTask_old", to: "jobTask")
        try db.create(index: "jobTask_jobID", on: "jobTask", columns: ["jobID"])
        try db.create(
            index: "jobTask_jobID_position", on: "jobTask", columns: ["jobID", "position"])
    }
}
