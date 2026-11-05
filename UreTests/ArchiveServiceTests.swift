import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct ArchiveServiceTests {
    private let clock = Date(timeIntervalSince1970: 1_700_000_000.25)

    @Test
    func aWatchWithAnOpenJobArchivesAndUnarchiveKeepsItsJobs() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = clock
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { clock }))
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let steps = try await ChecklistService(coordinator: coordinator).save(
            [ChecklistStep(id: UUID(), text: "Clean all parts")], for: job.id)
        let watchID = try #require(job.watchID)
        let prior = try #require(
            try await coordinator.read { try WatchQueries.fetch(watchID, in: $0) })
        let service = ArchiveService(coordinator: coordinator)
        let archived = try await service.setWatch(watchID, archived: true)
        #expect(archived.archivedAt == clock)
        #expect(archived.updatedAt == prior.updatedAt)
        #expect(
            try await coordinator.read { try SearchQueries.fetch(prior.name, in: $0) }.first {
                $0.recordID == prior.id
            }?.isArchived == true)

        // The open job stays in Jobs and can still change, also its state.
        #expect(
            try await coordinator.read { try JobListQueries.fetch($0, doneSince: .distantPast) }
                .map(\.id) == [job.id])
        let jobs = JobService(coordinator: coordinator)
        let renamed = try await jobs.update(job.id, .title("Service while archived"))
        try await RecordNotesService(coordinator: coordinator).save(
            "Still on the bench", for: .job(job.id))
        await #expect(throws: ArchiveError.archived) {
            try await WatchService(coordinator: coordinator).update(archived.id, .brand("Omega"))
        }
        let done = try await jobs.setStage(job.id, to: .done).job
        #expect(try await jobs.setStage(job.id, to: .inProgress).job.stage == .inProgress)
        let closed = try await jobs.restoreStage(job.id, to: JobStageValue(job: done))
        await #expect(throws: ArchiveError.archived) {
            try await jobs.start(for: archived.id)
        }
        try await coordinator.close()

        let reopened = fixture.coordinator()
        _ = try await reopened.open()
        #expect(try await reopened.read { try WatchQueries.fetch(prior.id, in: $0) } == archived)
        let restored = try await ArchiveService(coordinator: reopened).setWatch(
            prior.id, archived: false)
        #expect(restored == prior)
        #expect(try await reopened.read { try JobQueries.fetch(closed.id, in: $0) } == closed)
        #expect(closed.title == renamed.title && closed.stage == .done)
        #expect(try await reopened.read(ChecklistQueries.fetchAll) == steps)
        _ = try await JobService(coordinator: reopened).setStage(job.id, to: .inProgress)
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
        #expect(try await coordinator.read { try JobQueries.fetch(job.id, in: $0) } == job)
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
