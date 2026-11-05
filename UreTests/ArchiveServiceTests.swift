import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct ArchiveServiceTests {
    private let clock = Date(timeIntervalSince1970: 1_700_000_000.25)

    @Test
    func aWatchWithAnOpenJobArchivesAndUnarchiveKeepsItsJobsAndHistory() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = clock
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { clock }))
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let task = try await JobTaskService(coordinator: coordinator).save(
            JobTaskFixture.draft(.toDo), for: job.id, editing: nil)
        let events = try await coordinator.read(ActivityQueries.fetchAll)
        let prior = try #require(
            try await coordinator.read { try WatchQueries.fetch(job.watchID, in: $0) })
        let service = ArchiveService(coordinator: coordinator)
        let archived = try await service.setWatch(job.watchID, archived: true)
        #expect(archived.archivedAt == clock)
        #expect(archived.updatedAt == prior.updatedAt)
        #expect(
            try await coordinator.read { try SearchQueries.fetch(prior.name, in: $0) }.first {
                $0.recordID == prior.id
            }?.isArchived == true)

        // The open job stays in the workshop and can still change.
        #expect(try await coordinator.read(WorkshopQueries.fetch).map(\.id) == [job.id])
        var intake = JobDraft(job: job)
        intake.title = "Service while archived"
        let renamed = try await JobService(coordinator: coordinator).save(
            intake, for: job.watchID, editing: job.id)
        try await RecordNotesService(coordinator: coordinator).save(
            "Still on the bench", for: .job(job.id))
        await #expect(throws: ArchiveError.archived) {
            try await WatchService(coordinator: coordinator).update(archived.id, .brand("Omega"))
        }
        var closure = JobTransitionDraft(stage: .cancelled)
        closure.cancellationReason = "Keep for reference"
        closure.unfinishedTasksReason = "The owner collected the watch"
        let closed = try await JobService(coordinator: coordinator).transition(
            job.id, using: closure)
        await #expect(throws: ArchiveError.archived) {
            try await JobService(coordinator: coordinator).reopen(
                job.id, using: JobTransitionDraft(stage: .planned))
        }
        await #expect(throws: ArchiveError.archived) {
            try await JobService(coordinator: coordinator).save(
                JobDraft(), for: archived.id, editing: nil)
        }
        let history = try await coordinator.read(ActivityQueries.fetchAll)
        try await coordinator.close()

        let reopened = fixture.coordinator()
        _ = try await reopened.open()
        #expect(try await reopened.read { try WatchQueries.fetch(prior.id, in: $0) } == archived)
        let restored = try await ArchiveService(coordinator: reopened).setWatch(
            prior.id, archived: false)
        #expect(restored == prior)
        #expect(try await reopened.read(ActivityQueries.fetchAll) == history)
        #expect(history.count == events.count + 1)
        #expect(try await reopened.read { try JobQueries.fetch(closed.id, in: $0) } == closed)
        #expect(closed.title == renamed.title)
        #expect(try await reopened.read { try JobTaskQueries.fetch(task.id, in: $0) } == task)
        _ = try await JobService(coordinator: reopened).reopen(
            job.id, using: JobTransitionDraft(stage: .planned))
        try await reopened.close()
    }

    @Test
    func archivedCaliberKeepsExistingLinksAndIntakeButRejectsNewLinksAndWrites() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        _ = try await NoteFixture.owners(coordinator)
        let caliber = try #require(try await coordinator.read(CaliberQueries.fetchAll).first)
        let watch = try #require(try await coordinator.read(WatchQueries.fetchAll).first)
        let job = try #require(try await coordinator.read(JobQueries.fetchAll).first)
        let service = ArchiveService(coordinator: coordinator)
        let archived = try await service.setCaliber(caliber.id, archived: true)
        #expect(
            try await coordinator.read { try WatchQueries.fetch(watch.id, in: $0)?.caliberID }
                == caliber.id)
        let watches = WatchService(coordinator: coordinator)
        _ = try await watches.update(watch.id, .name("Updated linked watch"))
        let other = try await watches.create(named: "Another watch")
        await #expect(throws: ArchiveError.archived) {
            try await watches.update(other.id, .caliber(caliber.id))
        }
        await #expect(throws: ArchiveError.archived) {
            try await CaliberService(coordinator: coordinator).update(
                archived.id, .name("Renamed while archived"))
        }
        await #expect(throws: ArchiveError.archived) {
            try await RecordNotesService(coordinator: coordinator).save(
                "Shared finding", for: .caliber(caliber.id))
        }
        await #expect(throws: ArchiveError.archived) {
            try await MaterialService(coordinator: coordinator).addLink(
                try #require(URL(string: "https://example.org/manual.pdf")),
                for: .caliber(caliber.id))
        }
        #expect(
            try await coordinator.read { try JobQueries.fetch(job.id, in: $0)?.intakeSnapshot }
                == job.intakeSnapshot)
        let restored = try await service.setCaliber(caliber.id, archived: false)
        #expect(restored == caliber)
        try await coordinator.close()
    }

    @Test
    func failedArchiveRollsBackAndRepeatedArchiveDoesNotChangeTheSavedDate() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await WatchService(coordinator: coordinator).create(named: "Archive needle")
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql:
                    "CREATE TRIGGER failArchive BEFORE UPDATE ON watch BEGIN SELECT RAISE(ABORT, 'injected'); END"
            )
        }
        let service = ArchiveService(coordinator: coordinator)
        await #expect(throws: DatabaseError.self) {
            try await service.setWatch(watch.id, archived: true)
        }
        #expect(try await coordinator.read { try WatchQueries.fetch(watch.id, in: $0) } == watch)
        #expect(
            try await coordinator.read { try SearchQueries.fetch(watch.name, in: $0) }.count == 1)
        try await coordinator.mutate { db, _, _ in try db.execute(sql: "DROP TRIGGER failArchive") }
        let archived = try await service.setWatch(watch.id, archived: true)
        #expect(try await service.setWatch(watch.id, archived: true) == archived)
        try await coordinator.close()
    }
}
