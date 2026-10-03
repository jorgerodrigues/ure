import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct ArchiveServiceTests {
    private let clock = Date(timeIntervalSince1970: 1_700_000_000.25)

    @Test
    func openJobBlocksArchiveAndUnarchivePreservesHistoryAcrossRestart() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = clock
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { clock }))
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = ArchiveService(coordinator: coordinator)
        await #expect(throws: ArchiveError.openJob) {
            try await service.setWatch(job.watchID, archived: true)
        }
        var closure = JobTransitionDraft(stage: .cancelled)
        closure.cancellationReason = "Keep for reference"
        let closed = try await JobService(coordinator: coordinator).transition(
            job.id, using: closure)
        let events = try await coordinator.read(ActivityQueries.fetchAll)
        let prior = try #require(
            try await coordinator.read { try WatchQueries.fetch(job.watchID, in: $0) })
        let archived = try await service.setWatch(job.watchID, archived: true)
        #expect(archived.archivedAt == clock)
        #expect(archived.updatedAt == prior.updatedAt)
        #expect(try await coordinator.read { try SearchQueries.fetch(prior.name, in: $0) }.isEmpty)
        #expect(
            try await coordinator.read {
                try SearchQueries.fetch(prior.name, includeArchived: true, in: $0)
            }.contains { $0.recordID == prior.id })
        await #expect(throws: ArchiveError.archived) {
            try await JobService(coordinator: coordinator).reopen(
                job.id, using: JobTransitionDraft(stage: .planned))
        }
        await #expect(throws: ArchiveError.archived) {
            try await WatchService(coordinator: coordinator).save(
                WatchDraft(watch: archived), editing: archived.id)
        }
        await #expect(throws: ArchiveError.archived) {
            try await JobService(coordinator: coordinator).save(
                JobDraft(), for: archived.id, editing: nil)
        }
        try await coordinator.close()
        let reopened = fixture.coordinator()
        _ = try await reopened.open()
        #expect(try await reopened.read { try WatchQueries.fetch(prior.id, in: $0) } == archived)
        let restored = try await ArchiveService(coordinator: reopened).setWatch(
            prior.id, archived: false)
        #expect(restored == prior)
        #expect(try await reopened.read(ActivityQueries.fetchAll) == events)
        #expect(try await reopened.read { try JobQueries.fetch(closed.id, in: $0) } == closed)
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
        var draft = WatchDraft(watch: watch)
        draft.name = "Updated linked watch"
        _ = try await WatchService(coordinator: coordinator).save(draft, editing: watch.id)
        await #expect(throws: ArchiveError.archived) {
            try await WatchService(coordinator: coordinator).save(draft, editing: nil)
        }
        await #expect(throws: ArchiveError.archived) {
            try await CaliberService(coordinator: coordinator).save(
                CaliberDraft(caliber: archived), editing: caliber.id)
        }
        await #expect(throws: ArchiveError.archived) {
            try await NoteService(coordinator: coordinator).save(
                NoteDraft(), for: .caliber(caliber.id), editing: nil)
        }
        await #expect(throws: ArchiveError.archived) {
            try await ReferenceService(coordinator: coordinator).save(
                ReferenceFixture.draft, for: .caliber(caliber.id), editing: nil)
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
        var draft = WatchDraft()
        draft.name = "Archive needle"
        let watch = try await WatchService(coordinator: coordinator).save(draft, editing: nil)
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
