import Foundation
import GRDB
import Synchronization
import Testing

@testable import Ure

nonisolated struct JobTransitionTests {
    @Test(arguments: JobStage.allCases, JobStage.allCases)
    func everyStateChangeSetsItsDatesAndKeepsTheOpenedDate(from: JobStage, to: JobStage)
        async throws
    {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let opened = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = Mutex(opened)
        let coordinator = fixture.coordinator(
            dependencies: LibraryDependencies(now: { clock.withLock { $0 } }))
        _ = try await coordinator.open()
        let (watch, job) = try await makeJob(coordinator)
        let service = JobService(coordinator: coordinator)
        let first = opened.addingTimeInterval(60)
        clock.withLock { $0 = first }
        var prior = try await service.setStage(job.id, to: from).job
        if from == .waiting {
            prior = try await service.update(job.id, .waitingFor("A mainspring"))
        }
        let second = first.addingTimeInterval(60)
        clock.withLock { $0 = second }
        let change = try await service.setStage(job.id, to: to)
        let next = change.job
        #expect(change.prior == JobStageValue(job: prior))
        #expect(next.stage == to && next.createdAt == opened)
        if from == to {
            #expect(next == prior)
        } else {
            #expect(next.updatedAt == second)
            #expect(next.doneAt == (to == .done ? second : nil))
            #expect(next.waitingFor == nil)
        }
        #expect(try await coordinator.read { try JobQueries.fetch(job.id, in: $0) } == next)
        #expect(
            try await coordinator.read { db in try WatchQueries.fetch(watch.id, in: db) } == watch)
        try await coordinator.close()
    }

    @Test
    func restorePutsBackAStateWithItsDoneDateAndWaitingText() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let opened = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = Mutex(opened)
        let coordinator = fixture.coordinator(
            dependencies: LibraryDependencies(now: { clock.withLock { $0 } }))
        _ = try await coordinator.open()
        let (_, job) = try await makeJob(coordinator)
        let service = JobService(coordinator: coordinator)
        let doneDay = opened.addingTimeInterval(86_400)
        clock.withLock { $0 = doneDay }
        let done = try await service.setStage(job.id, to: .done)
        #expect(done.prior == JobStageValue(stage: .inProgress))
        #expect(done.job.doneAt == doneDay)

        let later = doneDay.addingTimeInterval(86_400)
        clock.withLock { $0 = later }
        let reopened = try await service.setStage(job.id, to: .inProgress)
        #expect(reopened.prior == JobStageValue(stage: .done, doneAt: doneDay))
        #expect(reopened.job.doneAt == nil)
        let undone = try await service.restoreStage(job.id, to: reopened.prior)
        #expect(undone.stage == .done && undone.doneAt == doneDay && undone.updatedAt == later)

        _ = try await service.restoreStage(job.id, to: JobStageValue(stage: .waiting))
        let waiting = try await service.update(job.id, .waitingFor(" A crystal from Cousins "))
        #expect(waiting.waitingFor == "A crystal from Cousins")
        let moved = try await service.setStage(job.id, to: .inProgress)
        #expect(moved.job.waitingFor == nil)
        #expect(moved.prior == JobStageValue(stage: .waiting, waitingFor: "A crystal from Cousins"))
        let back = try await service.restoreStage(job.id, to: moved.prior)
        #expect(back.stage == .waiting && back.waitingFor == "A crystal from Cousins")
        #expect(try await service.restoreStage(job.id, to: moved.prior) == back)
        try await coordinator.close()
    }

    @Test
    func aJobLeavingDoneCannotDisplaceAnotherOpenJob() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let (watch, job) = try await makeJob(coordinator)
        let service = JobService(coordinator: coordinator)
        let done = try await service.setStage(job.id, to: .done)
        let other = try await service.start(for: watch.id, title: "Next repair")
        for stage in [JobStage.inProgress, .waiting] {
            await #expect(throws: JobError.openJobExists(other)) {
                try await service.setStage(job.id, to: stage)
            }
        }
        await #expect(throws: JobError.openJobExists(other)) {
            try await service.restoreStage(job.id, to: done.prior)
        }
        #expect(try await coordinator.read { try JobQueries.fetch(job.id, in: $0) } == done.job)
        await #expect(throws: DatabaseError.self) {
            try await coordinator.mutate { db, _, _ in
                try db.execute(
                    sql: "UPDATE job SET stage = 'In progress', doneAt = NULL WHERE id = ?",
                    arguments: [job.id.uuidString])
            }
        }
        _ = try await service.setStage(other.id, to: .done)
        #expect(try await service.setStage(job.id, to: .waiting).job.stage == .waiting)
        try await coordinator.close()
    }

    @Test
    func theStateChangesWhileTheWatchIsArchivedButAnArchivedJobDoesNot() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let (watch, job) = try await makeJob(coordinator)
        let service = JobService(coordinator: coordinator)
        _ = try await ArchiveService(coordinator: coordinator).setWatch(watch.id, archived: true)
        let done = try await service.setStage(job.id, to: .done)
        let undone = try await service.restoreStage(job.id, to: done.prior)
        #expect(undone.stage == .inProgress && undone.doneAt == nil)
        try await coordinator.mutate { db, _, _ in
            try db.execute(sql: "UPDATE job SET archivedAt = 1")
        }
        await #expect(throws: ArchiveError.archived) {
            try await service.setStage(job.id, to: .done)
        }
        await #expect(throws: ArchiveError.archived) {
            try await service.update(job.id, .title("Archived"))
        }
        try await coordinator.close()
    }

    private func makeJob(_ coordinator: LibraryCoordinator) async throws -> (WatchRecord, JobRecord)
    {
        let watch = try await WatchService(coordinator: coordinator).make("Bench watch")
        let job = try await JobService(coordinator: coordinator).start(
            for: watch.id, title: "Inspect movement")
        return (watch, job)
    }
}

nonisolated enum JobMigrationFixture {
    static func removeStages(in db: Database) throws {
        try NoteMigrationFixture.removeNotes(in: db)
        try db.execute(sql: "DROP TABLE activityEvent")
        for column in ["condition", "conditionNote"] {
            try db.execute(sql: "ALTER TABLE watch DROP COLUMN \(column)")
        }
        for column in [
            "waitingReason", "outcome", "recommendations", "cancellationReason", "startedAt",
            "completedAt", "cancelledAt",
        ] {
            try db.execute(sql: "ALTER TABLE job DROP COLUMN \(column)")
        }
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v5-job-stages'")
    }
}
