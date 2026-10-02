import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct JobServiceTests {
    @Test
    func minimalAndCompleteIntakesSurviveRestart() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { date }))
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        var draft = JobDraft()
        draft.title = "  Inspect inherited watch  "
        let first = try await JobService(coordinator: coordinator).save(
            draft, for: watch.id, editing: nil)
        #expect(first.title == "Inspect inherited watch")
        #expect(first.stage == .planned)
        #expect(first.ownerName == nil)
        #expect(first.ownerEmail == nil)
        #expect(first.ownerPhone == nil)
        #expect(first.reportedProblem == nil)
        #expect(first.createdAt == date)
        #expect(first.intakeSnapshot.version == 1)
        #expect(first.intakeSnapshot.watchName == watch.name)
        #expect(first.intakeSnapshot.serial == "000042.7-A")
        #expect(first.intakeSnapshot.caliberDesignation == nil)
        let other = try await makeWatch(coordinator)
        draft.reportedProblem = "Stops overnight.\nCheck after winding."
        draft.agreedScope = "Inspection only"
        draft.intakeCondition = "Disassembled on arrival"
        draft.ownerName = "  Åse Øster  "
        draft.ownerEmail = "No email; call instead"
        draft.ownerPhone = "+45 (00) 0012 / daytime"
        let second = try await JobService(coordinator: coordinator).save(
            draft, for: other.id, editing: nil)
        #expect(second.ownerName == "Åse Øster")
        #expect(second.ownerEmail == draft.ownerEmail)
        #expect(second.ownerPhone == draft.ownerPhone)
        #expect(second.reportedProblem == draft.reportedProblem)
        #expect(second.agreedScope == draft.agreedScope)
        #expect(second.intakeCondition == draft.intakeCondition)
        let snapshotText = try await coordinator.read { db in
            try String.fetchOne(
                db, sql: "SELECT intakeSnapshot FROM job WHERE id = ?",
                arguments: [first.id.uuidString])
        }
        let text = try #require(snapshotText)
        let snapshot = try JSONDecoder().decode(JobIntakeSnapshot.self, from: Data(text.utf8))
        #expect(snapshot == first.intakeSnapshot)
        try await coordinator.close()
        let reopened = fixture.coordinator()
        _ = try await reopened.open()
        let records = try await reopened.read(JobQueries.fetchAll)
        #expect(records.count == 2)
        #expect(records.contains(first))
        #expect(records.contains(second))
        try await reopened.close()
    }

    @Test
    func watchAndCaliberChangesDoNotRewriteIntakeAndCorrectionsStayLocal() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        var caliberDraft = CaliberDraft()
        caliberDraft.designation = "0012–Å"
        caliberDraft.variant = "0002-A"
        let caliber = try await CaliberService(coordinator: coordinator).save(
            caliberDraft, editing: nil)
        var watchDraft = fixture.completeDraft
        watchDraft.caliberID = caliber.id
        let watch = try await WatchService(coordinator: coordinator).save(
            watchDraft, editing: nil, locale: Locale(identifier: "da_DK"))
        let service = JobService(coordinator: coordinator)
        var draft = JobDraft()
        draft.title = "First repair"
        let first = try await service.save(draft, for: watch.id, editing: nil)
        #expect(first.intakeSnapshot.caliberDesignation == "0012–Å")
        #expect(first.intakeSnapshot.caliberVariant == "0002-A")
        watchDraft.name = "Current name"
        watchDraft.serial = "Different serial"
        _ = try await WatchService(coordinator: coordinator).save(
            watchDraft, editing: watch.id, locale: Locale(identifier: "da_DK"))
        caliberDraft.designation = "Corrected designation"
        caliberDraft.variant = "B"
        _ = try await CaliberService(coordinator: coordinator).save(
            caliberDraft, editing: caliber.id)
        #expect(
            try await coordinator.read { db in try JobQueries.fetch(first.id, in: db) } == first)
        draft = JobDraft(job: first)
        draft.reportedProblem = "Corrected intake note"
        let edited = try await service.save(draft, for: watch.id, editing: first.id)
        #expect(edited.intakeSnapshot == first.intakeSnapshot)
        #expect(edited.createdAt == first.createdAt)
        draft.intake?.serial = "000042.7-B"
        let corrected = try await service.save(draft, for: watch.id, editing: first.id)
        #expect(corrected.intakeSnapshot.serial == "000042.7-B")
        #expect(
            try await coordinator.read { db in try WatchQueries.fetch(watch.id, in: db)?.serial }
                == "Different serial")
        #expect(
            try await coordinator.read { db in
                try CaliberQueries.fetch(caliber.id, in: db)?.designation
            } == "Corrected designation")
        try await coordinator.close()
    }

    @Test
    func invalidTitlesAndSnapshotNamesCommitNothing() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let service = JobService(coordinator: coordinator)
        var draft = JobDraft()
        draft.title = " \n "
        await #expect(throws: JobValidationError.self) {
            try await service.save(draft, for: watch.id, editing: nil)
        }
        #expect(try await coordinator.read(JobQueries.fetchAll).isEmpty)
        draft.title = "Repair"
        let first = try await service.save(draft, for: watch.id, editing: nil)
        draft = JobDraft(job: first)
        draft.intake?.watchName = " \n "
        await #expect(throws: JobValidationError.self) {
            try await service.save(draft, for: watch.id, editing: first.id)
        }
        #expect(try await coordinator.read(JobQueries.fetchAll) == [first])
        try await coordinator.close()
    }

    @Test
    func concurrentCreatesCommitExactlyOneOpenJob() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let service = JobService(coordinator: coordinator)
        var draft = JobDraft()
        draft.title = "One repair"
        let intake = draft
        let successes = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        _ = try await service.save(intake, for: watch.id, editing: nil)
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
        #expect(try await coordinator.read(JobQueries.fetchAll).count == 1)
        try await coordinator.close()
    }

    @Test(arguments: [JobStage.planned, .inProgress, .waiting, .ready])
    func databaseRejectsAnotherOpenJobEvenWithoutServiceValidation(stage: JobStage) async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        var draft = JobDraft()
        draft.title = "First repair"
        let first = try await JobService(coordinator: coordinator).save(
            draft, for: watch.id, editing: nil)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: "UPDATE job SET stage = ? WHERE id = ?",
                arguments: [stage.rawValue, first.id.uuidString])
        }
        let duplicate = try draft.record(
            id: UUID(), watchID: watch.id, stage: .planned, snapshot: first.intakeSnapshot,
            createdAt: first.createdAt, updatedAt: first.updatedAt)
        await #expect(throws: DatabaseError.self) {
            try await coordinator.mutate { db, _, _ in try JobQueries.insert(duplicate, in: db) }
        }
        #expect(try await coordinator.read(JobQueries.fetchAll).count == 1)
        try await coordinator.close()
    }

    @Test
    func closedHistoryAllowsANewJobButRejectsIntakeEdits() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let service = JobService(coordinator: coordinator)
        var draft = JobDraft()
        draft.title = "Earlier repair"
        let first = try await service.save(draft, for: watch.id, editing: nil)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: "UPDATE job SET stage = 'Completed' WHERE id = ?",
                arguments: [first.id.uuidString])
        }
        await #expect(throws: JobError.closedJob) {
            try await service.save(draft, for: watch.id, editing: first.id)
        }
        draft.title = "Later repair"
        let second = try await service.save(draft, for: watch.id, editing: nil)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: "UPDATE job SET stage = 'Cancelled' WHERE id = ?",
                arguments: [second.id.uuidString])
        }
        _ = try await service.save(draft, for: watch.id, editing: nil)
        #expect(try await coordinator.read(JobQueries.fetchAll).count == 3)
        #expect(
            try await coordinator.read { db in
                try JobQueries.fetch(first.id, in: db)?.intakeSnapshot
            } == first.intakeSnapshot)
        try await coordinator.close()
    }

    @Test
    func unavailableAndWrongWatchEditsCannotCreateOrMoveRecords() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let other = try await makeWatch(coordinator)
        let service = JobService(coordinator: coordinator)
        var draft = JobDraft()
        draft.title = "Repair"
        await #expect(throws: JobError.unavailableWatch) {
            try await service.save(draft, for: UUID(), editing: nil)
        }
        await #expect(throws: JobError.missingRecord) {
            try await service.save(draft, for: watch.id, editing: UUID())
        }
        let first = try await service.save(draft, for: watch.id, editing: nil)
        await #expect(throws: JobError.missingRecord) {
            try await service.save(draft, for: other.id, editing: first.id)
        }
        await #expect(throws: DatabaseError.self) {
            try await coordinator.mutate { db, _, _ in
                try db.execute(sql: "UPDATE job SET watchID = ?", arguments: [UUID().uuidString])
            }
        }
        #expect(try await coordinator.read(JobQueries.fetchAll) == [first])
        try await coordinator.close()
    }

    @Test
    func futureSnapshotCannotBeOverwrittenByAnEdit() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        var draft = JobDraft()
        draft.title = "Repair"
        let service = JobService(coordinator: coordinator)
        let first = try await service.save(draft, for: watch.id, editing: nil)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: "UPDATE job SET intakeSnapshot = json_set(intakeSnapshot, '$.version', 2)")
        }
        await #expect(throws: JobError.unsupportedSnapshot) {
            try await service.save(draft, for: watch.id, editing: first.id)
        }
        #expect(
            try await coordinator.read { db in
                try JobQueries.fetch(first.id, in: db)?.intakeSnapshot.version
            } == 2)
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
        var draft = JobDraft()
        draft.title = "Saved job"
        let service = JobService(coordinator: coordinator)
        let first = try await service.save(draft, for: watch.id, editing: nil)
        #expect(try await iterator.next() == [first])
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql:
                    "CREATE TRIGGER failJobUpdate BEFORE UPDATE ON job BEGIN SELECT RAISE(ABORT, 'fixture disk failure'); END"
            )
        }
        draft = JobDraft(job: first)
        draft.title = "Failed edit"
        await #expect(throws: DatabaseError.self) {
            try await service.save(draft, for: watch.id, editing: first.id)
        }
        #expect(try await coordinator.read(JobQueries.fetchAll) == [first])
        try await coordinator.mutate { db, _, _ in try db.execute(sql: "DROP TRIGGER failJobUpdate")
        }
        draft.title = "Committed edit"
        let last = try await service.save(draft, for: watch.id, editing: first.id)
        #expect(try await iterator.next() == [last])
        try await coordinator.close()
    }

    @Test
    func migrationFromCaliberLibraryPreservesRecordsAndOriginals() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let old = fixture.coordinator()
        let before = try await old.open()
        var caliberDraft = CaliberDraft()
        caliberDraft.designation = "0012"
        let caliber = try await CaliberService(coordinator: old).save(caliberDraft, editing: nil)
        var watchDraft = fixture.completeDraft
        watchDraft.caliberID = caliber.id
        let watch = try await WatchService(coordinator: old).save(
            watchDraft, editing: nil, locale: Locale(identifier: "da_DK"))
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
        try await WatchService(coordinator: coordinator).save(
            WatchFixture().completeDraft, editing: nil, locale: Locale(identifier: "da_DK"))
    }
}
