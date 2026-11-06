import Foundation
import GRDB
import Synchronization
import Testing

@testable import Ure

nonisolated struct JobServiceTests {
    @Test
    func aStartedJobIsInProgressWithItsOpenedDateAndSurvivesRestart() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { date }))
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let service = JobService(coordinator: coordinator)
        let first = try await service.start(for: watch.id)
        #expect(first.title == "New Job" && first.stage == .inProgress)
        #expect(first.createdAt == date && first.updatedAt == date)
        #expect(first.problem == nil && first.waitingFor == nil && first.doneAt == nil)
        let other = try await makeWatch(coordinator)
        let second = try await service.start(for: other.id, title: "  Inspect inherited watch  ")
        #expect(second.title == "Inspect inherited watch")
        try await coordinator.close()
        let reopened = fixture.coordinator()
        _ = try await reopened.open()
        #expect(
            try await reopened.read(JobQueries.fetchAll).sorted { $0.title < $1.title }
                == [first, second].sorted { $0.title < $1.title })
        try await reopened.close()
    }

    @Test
    func eachFactSavesOnItsOwnAndABlankTitleCommitsNothing() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = Mutex(created)
        let coordinator = fixture.coordinator(
            dependencies: LibraryDependencies(now: { clock.withLock { $0 } }))
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let service = JobService(coordinator: coordinator)
        let job = try await service.start(for: watch.id)
        let edited = created.addingTimeInterval(60)
        clock.withLock { $0 = edited }
        _ = try await service.update(job.id, .title("  Full service  "))
        let problem = "Loses about two minutes a day.\nThe crown feels gritty when winding."
        let saved = try await service.update(job.id, .problem("\n\(problem)  \n"))
        #expect(saved.title == "Full service" && saved.problem == problem)
        #expect(saved.updatedAt == edited && saved.createdAt == created)
        #expect(try await coordinator.read { try JobQueries.fetch(job.id, in: $0) } == saved)

        clock.withLock { $0 = edited.addingTimeInterval(60) }
        #expect(try await service.update(job.id, .problem(problem)) == saved)
        await #expect(throws: JobValidationError(message: "Write a title for this job.")) {
            try await service.update(job.id, .title(" \n "))
        }
        await #expect(throws: JobError.notWaiting) {
            try await service.update(job.id, .waitingFor("A mainspring"))
        }
        #expect(try await service.update(job.id, .waitingFor("  ")) == saved)
        let cleared = try await service.update(job.id, .problem(" \n "))
        #expect(cleared.problem == nil)
        await #expect(throws: JobError.missingRecord) {
            try await service.update(UUID(), .title("Missing"))
        }
        try await coordinator.close()
    }

    @Test
    func concurrentStartsCommitExactlyOneOpenJob() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let service = JobService(coordinator: coordinator)
        let successes = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        _ = try await service.start(for: watch.id)
                        return 1
                    } catch let error as JobError {
                        guard case .openJobExists = error else { throw error }
                        return 0
                    }
                }
            }
            var count = 0
            for try await result in group { count += result }
            return count
        }
        #expect(successes == 1)
        let open = try #require(try await coordinator.read(JobQueries.fetchAll).first)
        await #expect(throws: JobError.openJobExists(open)) {
            try await service.start(for: watch.id)
        }
        #expect(try await coordinator.read(JobQueries.fetchAll) == [open])
        try await coordinator.close()
    }

    @Test(arguments: [JobStage.inProgress, .waiting])
    func databaseRejectsAnotherOpenJobEvenWithoutServiceValidation(stage: JobStage) async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let first = try await JobService(coordinator: coordinator).start(for: watch.id)
        _ = try await JobService(coordinator: coordinator).setStage(first.id, to: stage)
        let duplicate = JobRecord(
            id: UUID(), watchID: watch.id, title: "Second repair", stage: .inProgress,
            createdAt: first.createdAt, updatedAt: first.updatedAt)
        await #expect(throws: DatabaseError.self) {
            try await coordinator.mutate { db, _, _ in try JobQueries.insert(duplicate, in: db) }
        }
        let done = JobRecord(
            id: UUID(), watchID: watch.id, title: "Earlier repair", stage: .done,
            createdAt: first.createdAt, updatedAt: first.updatedAt, doneAt: first.createdAt)
        try await coordinator.mutate { db, _, _ in try JobQueries.insert(done, in: db) }
        #expect(try await coordinator.read(JobQueries.fetchAll).count == 2)
        try await coordinator.close()
    }

    @Test
    func databaseKeepsTheDoneDateAndTheWaitingTextWithTheirStates() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let job = try await JobService(coordinator: coordinator).start(for: watch.id)
        for sql in [
            "UPDATE job SET stage = 'Done'", "UPDATE job SET doneAt = 1",
            "UPDATE job SET waitingFor = 'A mainspring'", "UPDATE job SET stage = 'Planned'",
        ] {
            await #expect(throws: DatabaseError.self) {
                try await coordinator.mutate { db, _, _ in try db.execute(sql: sql) }
            }
        }
        #expect(try await coordinator.read(JobQueries.fetchAll) == [job])
        try await coordinator.close()
    }

    @Test
    func startingNeedsAWatchThatIsInTheLibraryAndNotArchived() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let service = JobService(coordinator: coordinator)
        await #expect(throws: JobError.unavailableWatch) {
            try await service.start(for: UUID())
        }
        _ = try await ArchiveService(coordinator: coordinator).setWatch(watch.id, archived: true)
        await #expect(throws: ArchiveError.archived) {
            try await service.start(for: watch.id)
        }
        #expect(try await coordinator.read(JobQueries.fetchAll).isEmpty)
        await #expect(throws: JobValidationError.self) {
            try await service.start(for: try await makeWatch(coordinator).id, title: " ")
        }
        #expect(try await coordinator.read(JobQueries.fetchAll).isEmpty)
        try await coordinator.close()
    }

    @Test
    func aDoneJobTakesEditsWithItsChecklistPartsNotesAndMaterial() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let service = JobService(coordinator: coordinator)
        let job = try await service.start(for: watch.id, title: "Full service")
        let checklist = ChecklistService(coordinator: coordinator)
        let first = ChecklistStep(id: UUID(), text: "Fit the crystal")
        _ = try await checklist.save([first], for: job.id)
        let parts = PartService(coordinator: coordinator)
        let part = try await parts.add(named: "Crystal", to: job.id)
        let done = try await service.setStage(job.id, to: .done).job
        #expect(done.stage == .done)

        let renamed = try await service.update(job.id, .title("Full service and crystal"))
        #expect(renamed.stage == .done && renamed.doneAt == done.doneAt)
        _ = try await service.update(job.id, .problem("Crystal cracked at the bench."))
        var ticked = first
        ticked.isTicked = true
        let second = ChecklistStep(id: UUID(), text: "Pressure test")
        #expect(
            try await checklist.save([second, ticked], for: job.id).map(\.isTicked)
                == [false, true])
        #expect(try await parts.advance(part.id).part.stage == .ordered)
        try await RecordNotesService(coordinator: coordinator).save(
            "Fitted a new crystal after it was done.", for: .job(job.id))
        let link = try await MaterialService(coordinator: coordinator).addLink(
            try #require(URL(string: "https://example.org/crystal")), for: .job(job.id))
        #expect(link.jobID == job.id)
        #expect(try await checklist.save([second], for: job.id).map(\.id) == [second.id])
        let saved = try #require(
            try await coordinator.read { try JobQueries.fetch(job.id, in: $0) })
        #expect(saved.stage == .done && saved.problem == "Crystal cracked at the bench.")
        #expect(
            try await RecordNotesService(coordinator: coordinator).text(for: .job(job.id))
                == "Fitted a new crystal after it was done.")
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func observationPublishesCommittedJobsAndFailedWritesLeaveSavedData() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let values = try await coordinator.jobValues()
        var iterator = values.makeAsyncIterator()
        #expect(try await iterator.next() == [])
        let service = JobService(coordinator: coordinator)
        let first = try await service.start(for: watch.id, title: "Saved job")
        #expect(try await iterator.next() == [first])
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql:
                    "CREATE TRIGGER failJobUpdate BEFORE UPDATE ON job BEGIN SELECT RAISE(ABORT, 'fixture disk failure'); END"
            )
        }
        await #expect(throws: DatabaseError.self) {
            try await service.update(first.id, .title("Failed edit"))
        }
        await #expect(throws: DatabaseError.self) {
            try await service.setStage(first.id, to: .done)
        }
        #expect(try await coordinator.read(JobQueries.fetchAll) == [first])
        try await coordinator.mutate { db, _, _ in try db.execute(sql: "DROP TRIGGER failJobUpdate")
        }
        let last = try await service.update(first.id, .title("Committed edit"))
        #expect(try await iterator.next() == [last])
        try await coordinator.close()
    }

    @Test
    func migrationFromCaliberLibraryPreservesRecordsAndOriginals() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let old = fixture.coordinator()
        let before = try await old.open()
        let caliber = try await CaliberService(coordinator: old).create(named: "0012")
        let watch = try await WatchFixture.completeWatch(old, caliberID: caliber.id)
        let bytes = Data("original evidence".utf8)
        try await old.mutate { db, originals, _ in
            try JobMigrationFixture.removeStages(in: db)
            try db.execute(sql: "DROP TABLE job")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v4-jobs'")
            try bytes.write(to: originals.appending(path: "evidence.bin"))
        }
        try await old.close()
        let upgraded = fixture.coordinator()
        let after = try await upgraded.open()
        #expect(after.manifest == before.manifest)
        #expect(after.generationID != before.generationID)
        #expect(try await upgraded.read(WatchQueries.fetchAll) == [watch])
        #expect(try await upgraded.read(CaliberQueries.fetchAll) == [caliber])
        #expect(try await upgraded.read(JobQueries.fetchAll).isEmpty)
        #expect(
            try Data(
                contentsOf: LibraryFiles.generation(after.generationID, in: fixture.root).appending(
                    path: "originals/evidence.bin")) == bytes)
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.root.appending(path: "recovery").path
            ).count == 1)
        try await upgraded.close()
    }

    private func makeWatch(_ coordinator: LibraryCoordinator) async throws -> WatchRecord {
        try await WatchFixture.completeWatch(coordinator)
    }
}
