import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct NoteServiceTests {
    @Test(arguments: NoteKind.allCases)
    func allScopesAndKindsPreserveLongUnicodePlainTextAfterRestart(kind: NoteKind) async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = Date(timeIntervalSinceReferenceDate: 800_000_000.0000001)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { clock }))
        _ = try await coordinator.open()
        let owners = try await NoteFixture.owners(coordinator)
        let service = NoteService(coordinator: coordinator)
        var draft = NoteDraft(occurredAt: Date(timeIntervalSince1970: 1_600_000_000.125))
        draft.title = "  Research – Å時計 🔧  "
        draft.kind = kind
        draft.body = String(
            repeating: "  Ångström 時計 🔧 e\u{301}\n<script>plain text</script>\n", count: 2000)
        var saved: [NoteRecord] = []
        for owner in owners {
            let note = try await service.save(draft, for: owner, editing: nil)
            #expect(note.belongs(to: owner))
            #expect(note.title == "Research – Å時計 🔧")
            #expect(note.body == draft.body)
            #expect(note.kind == kind)
            #expect(note.createdAt == Date(timeIntervalSince1970: clock.timeIntervalSince1970))
            #expect(note.updatedAt == note.createdAt)
            #expect(note.occurredAt == draft.occurredAt)
            saved.append(note)
        }
        try await coordinator.close()
        let reopened = fixture.coordinator()
        _ = try await reopened.open()
        let restored = try await reopened.read(NoteQueries.fetchAll)
        #expect(restored.count == 3)
        #expect(saved.allSatisfy { restored.contains($0) })
        for owner in owners { #expect(restored.filter { $0.belongs(to: owner) }.count == 1) }
        try await reopened.close()
    }

    @Test
    func editsPreserveOccurrenceAndCreationUntilDateIsExplicitlyChanged() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let old = fixture.coordinator(dependencies: LibraryDependencies(now: { created }))
        _ = try await old.open()
        let owner = try #require(try await NoteFixture.owners(old).first)
        var draft = NoteDraft(occurredAt: created.addingTimeInterval(-86_400))
        draft.title = "Inspection"
        let first = try await NoteService(coordinator: old).save(draft, for: owner, editing: nil)
        try await old.close()
        let updated = created.addingTimeInterval(3600)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { updated }))
        _ = try await coordinator.open()
        let service = NoteService(coordinator: coordinator)
        var edit = NoteDraft(note: first)
        edit.body = "Corrected finding"
        let saved = try await service.save(edit, for: owner, editing: first.id)
        #expect(saved.id == first.id)
        #expect(saved.occurredAt == first.occurredAt)
        #expect(saved.createdAt == created)
        #expect(saved.updatedAt == updated)
        edit.occurredAt = updated.addingTimeInterval(-7200)
        let corrected = try await service.save(edit, for: owner, editing: first.id)
        #expect(corrected.occurredAt == edit.occurredAt)
        #expect(corrected.createdAt == created)
        #expect(try await coordinator.read(NoteQueries.fetchAll) == [corrected])
        try await coordinator.close()
    }

    @Test
    func databaseRejectsInvalidOwnersAndKindsAndMissingReferences() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owners = try await NoteFixture.owners(coordinator)
        let watch = try #require(owners.first)
        var draft = NoteDraft()
        draft.title = "Saved"
        let saved = try await NoteService(coordinator: coordinator).save(
            draft, for: watch, editing: nil)
        for sql in [
            "UPDATE note SET watchID = NULL",
            "UPDATE note SET jobID = (SELECT id FROM job LIMIT 1)",
            "UPDATE note SET caliberID = (SELECT id FROM caliber LIMIT 1)",
            "UPDATE note SET watchID = NULL, jobID = (SELECT id FROM job LIMIT 1), caliberID = (SELECT id FROM caliber LIMIT 1)",
            "UPDATE note SET jobID = (SELECT id FROM job LIMIT 1), caliberID = (SELECT id FROM caliber LIMIT 1)",
            "UPDATE note SET kind = 'Unsupported'",
            "UPDATE note SET watchID = 'MISSING'",
        ] {
            await #expect(throws: DatabaseError.self) {
                try await coordinator.mutate { db, _, _ in try db.execute(sql: sql) }
            }
        }
        for owner in [NoteOwner.watch(UUID()), .job(UUID()), .caliber(UUID())] {
            await #expect(throws: (any Error).self) {
                try await NoteService(coordinator: coordinator).save(
                    draft, for: owner, editing: nil)
            }
        }
        await #expect(throws: NoteError.ownerMismatch) {
            try await NoteService(coordinator: coordinator).save(
                draft, for: owners[2], editing: saved.id)
        }
        await #expect(throws: NoteError.missingRecord) {
            try await NoteService(coordinator: coordinator).save(draft, for: watch, editing: UUID())
        }
        #expect(try await coordinator.read(NoteQueries.fetchAll) == [saved])
        try await coordinator.close()
    }

    @Test(arguments: [JobStage.completed, .cancelled])
    func closedJobRejectsNewAndEditedNotesUntilReopened(stage: JobStage) async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owners = try await NoteFixture.owners(coordinator)
        let jobOwner = owners[1]
        guard case .job(let jobID) = jobOwner else { throw NoteFixtureError() }
        let service = NoteService(coordinator: coordinator)
        var draft = NoteDraft()
        draft.title = "Inspection"
        let saved = try await service.save(draft, for: jobOwner, editing: nil)
        var closure = JobTransitionDraft(stage: stage)
        closure.outcome = "Serviced"
        closure.cancellationReason = "Owner declined"
        let jobs = JobService(coordinator: coordinator)
        _ = try await jobs.transition(jobID, using: closure)
        draft.body = "Changed"
        await #expect(throws: JobError.closedJob) {
            try await service.save(draft, for: jobOwner, editing: saved.id)
        }
        await #expect(throws: JobError.closedJob) {
            try await service.save(draft, for: jobOwner, editing: nil)
        }
        #expect(try await coordinator.read(NoteQueries.fetchAll) == [saved])
        _ = try await service.save(draft, for: owners[0], editing: nil)
        _ = try await service.save(draft, for: owners[2], editing: nil)
        _ = try await jobs.reopen(jobID, using: JobTransitionDraft(stage: .planned))
        let edited = try await service.save(draft, for: jobOwner, editing: saved.id)
        #expect(edited.body == "Changed")
        #expect(edited.occurredAt == saved.occurredAt)
        try await coordinator.close()
    }

    @Test
    func forwardMigrationPreservesExistingRecordsEventsAndOriginals() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let old = fixture.coordinator()
        let before = try await old.open()
        let owners = try await NoteFixture.owners(old)
        guard case .job(let jobID) = owners[1] else { throw NoteFixtureError() }
        _ = try await JobService(coordinator: old).transition(
            jobID, using: JobTransitionDraft(stage: .inProgress))
        let watches = try await old.read(WatchQueries.fetchAll)
        let calibers = try await old.read(CaliberQueries.fetchAll)
        let jobs = try await old.read(JobQueries.fetchAll)
        let events = try await old.read(ActivityQueries.fetchAll)
        let bytes = Data("original evidence".utf8)
        try await old.mutate { db, originals, _ in
            try NoteMigrationFixture.removeNotes(in: db)
            try bytes.write(to: originals.appending(path: "evidence.bin"))
        }
        try await old.close()
        let upgraded = fixture.coordinator()
        let after = try await upgraded.open()
        #expect(after.generationID != before.generationID)
        #expect(after.manifest == before.manifest)
        #expect(try await upgraded.read(WatchQueries.fetchAll) == watches)
        #expect(try await upgraded.read(CaliberQueries.fetchAll) == calibers)
        #expect(try await upgraded.read(JobQueries.fetchAll) == jobs)
        #expect(try await upgraded.read(ActivityQueries.fetchAll) == events)
        #expect(try await upgraded.read(NoteQueries.fetchAll).isEmpty)
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
}

nonisolated enum NoteFixture {
    static func owners(_ coordinator: LibraryCoordinator) async throws -> [NoteOwner] {
        var caliberDraft = CaliberDraft()
        caliberDraft.designation = "0012–Å"
        let caliber = try await CaliberService(coordinator: coordinator).save(
            caliberDraft, editing: nil)
        var watchDraft = WatchDraft()
        watchDraft.name = "Bench watch"
        watchDraft.caliberID = caliber.id
        let watch = try await WatchService(coordinator: coordinator).save(watchDraft, editing: nil)
        var jobDraft = JobDraft()
        jobDraft.title = "Inspect movement"
        let job = try await JobService(coordinator: coordinator).save(
            jobDraft, for: watch.id, editing: nil)
        return [.watch(watch.id), .job(job.id), .caliber(caliber.id)]
    }
}

nonisolated enum NoteMigrationFixture {
    static func removeNotes(in db: Database) throws {
        try ReferenceMigrationFixture.removeLinks(in: db)
        try db.execute(sql: "DROP TABLE note")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v6-notes'")
    }
}

nonisolated struct NoteFixtureError: Error {}
