import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct JobTransitionTests {
    @Test
    func stageChangesAndReopenPreserveUnknownIntakeSnapshotKeys() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let (_, job) = try await makeJob(coordinator)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql:
                    "UPDATE job SET intakeSnapshot = json_set(intakeSnapshot, '$.version', 2, '$.futureEvidence', 'keep these bytes') WHERE id = ?",
                arguments: [job.id.uuidString])
        }
        let before = try await coordinator.read { db in
            try String.fetchOne(
                db, sql: "SELECT intakeSnapshot FROM job WHERE id = ?",
                arguments: [job.id.uuidString])
        }
        let service = JobService(coordinator: coordinator)
        _ = try await service.transition(job.id, using: draft(.waiting))
        _ = try await service.transition(job.id, using: draft(.completed))
        _ = try await service.reopen(job.id, using: draft(.inProgress))
        let after = try await coordinator.read { db in
            try String.fetchOne(
                db, sql: "SELECT intakeSnapshot FROM job WHERE id = ?",
                arguments: [job.id.uuidString])
        }
        #expect(after == before)
        #expect(try await coordinator.read(ActivityQueries.fetchAll).count == 3)
        try await coordinator.close()
    }

    @Test(arguments: [
        Date(timeIntervalSinceReferenceDate: 800_000_000.0000001),
        Date(timeIntervalSince1970: 1_778_307_200 + 21.0 / 4_194_304),
    ])
    func subsecondClockValuesRoundTripWithReturnedRecordsAndEvents(clock: Date) async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let storedDate = Date(timeIntervalSince1970: clock.timeIntervalSince1970)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { clock }))
        _ = try await coordinator.open()
        let (_, job) = try await makeJob(coordinator)
        let service = JobService(coordinator: coordinator)
        let started = try await service.transition(job.id, using: draft(.inProgress))
        #expect(started.startedAt == storedDate)
        #expect(try await coordinator.read(JobQueries.fetchAll) == [started])
        let watch = try await service.setCondition(
            job.id, using: WatchConditionDraft(condition: .running, note: "Bench test"))
        #expect(watch.updatedAt == storedDate)
        #expect(try await coordinator.read(WatchQueries.fetchAll) == [watch])
        let closed = try await service.transition(job.id, using: draft(.completed))
        #expect(closed.completedAt == storedDate)
        #expect(try await coordinator.read(JobQueries.fetchAll) == [closed])
        let events = try await coordinator.read(ActivityQueries.fetchAll)
        #expect(events.map(\.ordering) == [1, 2, 3])
        #expect(events.allSatisfy { $0.occurredAt == storedDate })
        #expect(events.last?.nextValue == .job(JobStageValue(job: closed)))
        try await coordinator.close()
    }

    @Test(arguments: [JobStage.planned, .inProgress, .waiting, .ready], JobStage.allCases)
    func everyOpenStageCanMoveToEveryStage(from: JobStage, to: JobStage) async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { date }))
        _ = try await coordinator.open()
        let (watch, initial) = try await makeJob(coordinator)
        let service = JobService(coordinator: coordinator)
        let prior = try await service.transition(initial.id, using: draft(from))
        let before = try await coordinator.read(ActivityQueries.fetchAll)
        let next = try await service.transition(initial.id, using: draft(to))
        #expect(next.stage == to)
        #expect(next.intakeSnapshot == initial.intakeSnapshot)
        #expect(next.waitingReason == (to == .waiting ? "Waiting for evidence" : nil))
        #expect(next.completedAt == (to == .completed ? date : nil))
        #expect(next.cancelledAt == (to == .cancelled ? date : nil))
        if to == .inProgress { #expect(next.startedAt == date) }
        if to == .completed {
            #expect(next.outcome == "Movement serviced")
            #expect(next.recommendations == "Check timekeeping")
        }
        if to == .cancelled { #expect(next.cancellationReason == "Owner declined repair") }
        let events = try await coordinator.read(ActivityQueries.fetchAll)
        if from == to {
            #expect(events == before)
        } else {
            #expect(events.count == before.count + 1)
            let event = try #require(events.last)
            #expect(event.jobID == initial.id)
            #expect(event.kind == .jobStageChanged)
            #expect(event.occurredAt == date)
            #expect(event.priorValue == .job(JobStageValue(job: prior)))
            #expect(event.nextValue == .job(JobStageValue(job: next)))
        }
        #expect(
            try await coordinator.read { db in try WatchQueries.fetch(watch.id, in: db) } == watch)
        try await coordinator.close()
    }

    @Test(arguments: [JobStage.waiting, .completed, .cancelled])
    func requiredFieldsRejectWhitespaceWithoutStateOrEvents(stage: JobStage) async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let (_, job) = try await makeJob(coordinator)
        var change = JobTransitionDraft(stage: stage)
        change.waitingReason = " \n "
        change.outcome = " \t "
        change.cancellationReason = " \n "
        await #expect(throws: JobValidationError.self) {
            try await JobService(coordinator: coordinator).transition(job.id, using: change)
        }
        #expect(try await coordinator.read(JobQueries.fetchAll) == [job])
        #expect(try await coordinator.read(ActivityQueries.fetchAll).isEmpty)
        try await coordinator.close()
    }

    @Test(arguments: WatchCondition.allCases)
    func conditionAndNoteChangesDoNotMoveTheJobAndSurviveRestart(condition: WatchCondition)
        async throws
    {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let (watch, job) = try await makeJob(coordinator)
        let service = JobService(coordinator: coordinator)
        let waiting = try await service.transition(job.id, using: draft(.waiting))
        let change = WatchConditionDraft(condition: condition, note: "  Measured at the bench  ")
        let updated = try await service.setCondition(job.id, using: change)
        #expect(updated.condition == condition)
        #expect(updated.conditionNote == "Measured at the bench")
        #expect(try await coordinator.read(JobQueries.fetchAll) == [waiting])
        let events = try await coordinator.read(ActivityQueries.fetchAll)
        let event = try #require(events.last)
        #expect(event.kind == .watchConditionChanged)
        #expect(event.priorValue == .condition(WatchConditionValue(watch: watch)))
        #expect(event.nextValue == .condition(WatchConditionValue(watch: updated)))
        _ = try await service.setCondition(job.id, using: change)
        #expect(try await coordinator.read(ActivityQueries.fetchAll) == events)
        var identity = WatchDraft(watch: watch)
        identity.name = "Corrected identity"
        let renamed = try await WatchService(coordinator: coordinator).save(
            identity, editing: watch.id)
        #expect(renamed.condition == condition)
        #expect(renamed.conditionNote == updated.conditionNote)
        _ = try await service.save(JobDraft(job: waiting), for: watch.id, editing: job.id)
        #expect(
            try await coordinator.read { db in try JobQueries.fetch(job.id, in: db)?.waitingReason }
                == waiting.waitingReason)
        try await coordinator.close()
        let restarted = fixture.coordinator()
        _ = try await restarted.open()
        #expect(try await restarted.read(WatchQueries.fetchAll) == [renamed])
        #expect(try await restarted.read(ActivityQueries.fetchAll) == events)
        let cleared = try await JobService(coordinator: restarted).setCondition(
            job.id, using: WatchConditionDraft(condition: condition, note: " \n "))
        #expect(cleared.conditionNote == nil)
        #expect(try await restarted.read(ActivityQueries.fetchAll).count == events.count + 1)
        try await restarted.close()
    }

    @Test(
        arguments: [JobStage.completed, .cancelled],
        [JobStage.planned, .inProgress, .waiting, .ready])
    func closureLocksEditsAndReopenPreservesHistory(closed: JobStage, reopened: JobStage)
        async throws
    {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let (watch, job) = try await makeJob(coordinator)
        let service = JobService(coordinator: coordinator)
        let started = try await service.transition(job.id, using: draft(.inProgress))
        let closure = try await service.transition(job.id, using: draft(closed))
        let before = try await coordinator.read(ActivityQueries.fetchAll)
        await #expect(throws: JobError.closedJob) {
            try await service.save(JobDraft(job: closure), for: watch.id, editing: job.id)
        }
        await #expect(throws: JobError.closedJob) {
            try await service.transition(job.id, using: draft(.ready))
        }
        await #expect(throws: JobError.closedJob) {
            try await service.setCondition(
                job.id, using: WatchConditionDraft(condition: .running, note: ""))
        }
        await #expect(throws: JobError.invalidReopenStage) {
            try await service.reopen(job.id, using: draft(.completed))
        }
        #expect(try await coordinator.read(ActivityQueries.fetchAll) == before)
        #expect(try await coordinator.read(JobQueries.fetchAll) == [closure])
        let open = try await service.reopen(job.id, using: draft(reopened))
        #expect(open.stage == reopened)
        #expect(open.completedAt == nil)
        #expect(open.cancelledAt == nil)
        #expect(open.startedAt == started.startedAt)
        #expect(open.outcome == closure.outcome)
        let events = try await coordinator.read(ActivityQueries.fetchAll)
        #expect(Array(events.prefix(before.count)) == before)
        #expect(events.last?.priorValue == .job(JobStageValue(job: closure)))
        #expect(events.last?.nextValue == .job(JobStageValue(job: open)))
        await #expect(throws: JobError.notClosed) {
            try await service.reopen(job.id, using: draft(.planned))
        }
        try await coordinator.close()
    }

    @Test
    func reopeningCannotDisplaceAnotherOpenJob() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let (watch, job) = try await makeJob(coordinator)
        let service = JobService(coordinator: coordinator)
        let closed = try await service.transition(job.id, using: draft(.completed))
        var intake = JobDraft()
        intake.title = "Next repair"
        let other = try await service.save(intake, for: watch.id, editing: nil)
        let before = try await coordinator.read(ActivityQueries.fetchAll)
        await #expect(throws: JobError.openJobExists(other)) {
            try await service.reopen(job.id, using: draft(.inProgress))
        }
        #expect(try await coordinator.read { db in try JobQueries.fetch(job.id, in: db) } == closed)
        #expect(try await coordinator.read(ActivityQueries.fetchAll) == before)
        await #expect(throws: DatabaseError.self) {
            try await coordinator.mutate { db, _, _ in
                try db.execute(
                    sql: "UPDATE job SET stage = 'Planned' WHERE id = ?",
                    arguments: [job.id.uuidString])
            }
        }
        try await coordinator.close()
    }

    @Test(arguments: [false, true])
    func failedEventInsertRollsBackItsStateChange(condition: Bool) async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let (watch, job) = try await makeJob(coordinator)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql:
                    "CREATE TRIGGER failEvent BEFORE INSERT ON activityEvent BEGIN SELECT RAISE(ABORT, 'fixture event failure'); END"
            )
        }
        let service = JobService(coordinator: coordinator)
        await #expect(throws: DatabaseError.self) {
            if condition {
                _ = try await service.setCondition(
                    job.id,
                    using: WatchConditionDraft(condition: .disassembled, note: "Removed movement"))
            } else {
                _ = try await service.transition(job.id, using: draft(.completed))
            }
        }
        #expect(try await coordinator.read(JobQueries.fetchAll) == [job])
        #expect(try await coordinator.read(WatchQueries.fetchAll) == [watch])
        #expect(try await coordinator.read(ActivityQueries.fetchAll).isEmpty)
        try await coordinator.close()
    }

    @Test
    func migrationPreservesIntakeAndOriginalsWithoutInventingHistory() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        let before = try await coordinator.open()
        let (watch, job) = try await makeJob(coordinator)
        let bytes = Data("original evidence".utf8)
        try await coordinator.mutate { db, originals, _ in
            try JobMigrationFixture.removeStages(in: db)
            try bytes.write(to: originals.appending(path: "evidence.bin"))
        }
        try await coordinator.close()
        let upgraded = fixture.coordinator()
        let after = try await upgraded.open()
        #expect(after.generationID != before.generationID)
        #expect(after.manifest == before.manifest)
        #expect(try await upgraded.read(WatchQueries.fetchAll) == [watch])
        #expect(try await upgraded.read(JobQueries.fetchAll) == [job])
        #expect(try await upgraded.read(ActivityQueries.fetchAll).isEmpty)
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

    private func makeJob(_ coordinator: LibraryCoordinator) async throws -> (WatchRecord, JobRecord)
    {
        var watchDraft = WatchDraft()
        watchDraft.name = "Bench watch"
        let watch = try await WatchService(coordinator: coordinator).save(watchDraft, editing: nil)
        var intake = JobDraft()
        intake.title = "Inspect movement"
        let job = try await JobService(coordinator: coordinator).save(
            intake, for: watch.id, editing: nil)
        return (watch, job)
    }

    private func draft(_ stage: JobStage) -> JobTransitionDraft {
        var draft = JobTransitionDraft(stage: stage)
        draft.waitingReason = "  Waiting for evidence  "
        draft.outcome = "  Movement serviced  "
        draft.recommendations = "  Check timekeeping  "
        draft.cancellationReason = "  Owner declined repair  "
        return draft
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
