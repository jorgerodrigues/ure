import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct PartServiceTests {
    @Test(arguments: PartCompatibility.allCases)
    func referencesAndSeveralURLOnlyLinksSurviveRestart(compatibility: PartCompatibility)
        async throws
    {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        var draft = PartFixture.draft()
        draft.manufacturerReference = "0012.3–Å/04"
        draft.compatibility = compatibility
        draft.compatibilityNote = "Compared with the original and caliber sheet."
        draft.links = [PartLinkDraft(url: "https://example.org/parts/0012?variant=A")]
        let first = try await service.save(draft, for: job.id, editing: nil)
        var edit = PartDraft(part: first)
        edit.links.append(PartLinkDraft(url: "http://example.org/reference#drawing"))
        let saved = try await service.save(edit, for: job.id, editing: first.id)
        #expect(saved.record.manufacturerReference == "0012.3–Å/04")
        #expect(saved.record.status == .needed && saved.record.quantity == 1)
        #expect(saved.record.compatibility == compatibility)
        #expect(saved.links.first == first.links.first)
        #expect(saved.links.map(\.url) == edit.links.map(\.url))
        #expect(try await coordinator.read(JobQueries.fetchAll) == [job])
        #expect(try await coordinator.read(ActivityQueries.fetchAll).isEmpty)
        try await coordinator.close()
        let reopened = fixture.coordinator()
        _ = try await reopened.open()
        #expect(try await reopened.read(PartQueries.fetchAll) == [saved])
        try await reopened.close()
    }

    @Test(arguments: ["", "0", "-1", "1.5", "+2", "2e3", "NaN", "１２", "9999999999999999999999"])
    func quantityMustBeAPositiveWholeNumber(quantity: String) async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        var draft = PartFixture.draft()
        draft.quantity = quantity
        await #expect(throws: PartValidationError.self) {
            try await PartService(coordinator: coordinator).save(draft, for: job.id, editing: nil)
        }
        #expect(try await coordinator.read(PartQueries.fetchAll).isEmpty)
        try await coordinator.close()
    }

    @Test
    func optionalReferencesLinksAndCompatibilityValidation() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        let first = try await service.save(PartFixture.draft(), for: job.id, editing: nil)
        #expect(first.links.isEmpty && first.record.manufacturerReference == nil)
        var draft = PartDraft(part: first)
        draft.quantity = " 002 "
        draft.compatibility = .confirmed
        draft.compatibilityNote = " \n\t "
        await #expect(throws: PartValidationError.self) {
            try await service.save(draft, for: job.id, editing: first.id)
        }
        draft.compatibility = .unsuitable
        let unsuitable = try await service.save(draft, for: job.id, editing: first.id)
        #expect(unsuitable.record.compatibility == .unsuitable && unsuitable.record.quantity == 2)
        draft.description = " \n\t "
        await #expect(throws: PartValidationError.self) {
            try await service.save(draft, for: job.id, editing: first.id)
        }
        for url in [
            "", "file:///tmp/a", "javascript:alert(1)", "ftp://example.org/a", "https://",
            "https://example.org/a b",
        ] {
            var invalid = PartDraft(part: unsuitable)
            invalid.links = [PartLinkDraft(url: url)]
            await #expect(throws: PartValidationError.self) {
                try await service.save(invalid, for: job.id, editing: first.id)
            }
        }
        for sql in [
            "UPDATE partRequirement SET quantity = 0", "UPDATE partRequirement SET quantity = 1.5",
            "UPDATE partRequirement SET description = ''",
            "UPDATE partRequirement SET compatibility = 'Confirmed'",
            "UPDATE partRequirement SET compatibility = 'Unknown'",
            "UPDATE partRequirement SET jobID = 'MISSING'",
            "UPDATE partRequirement SET status = 'Unknown'",
        ] {
            await #expect(throws: DatabaseError.self) {
                try await coordinator.mutate { db, _, _ in try db.execute(sql: sql) }
            }
        }
        #expect(try await coordinator.read(PartQueries.fetchAll) == [unsuitable])
        try await coordinator.close()
    }

    @Test
    func ownershipFailuresAndLinkFailureRollBackEveryChange() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let other = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        var draft = PartFixture.draft()
        draft.links = [PartLinkDraft(url: "https://example.org/first")]
        let first = try await service.save(draft, for: job.id, editing: nil)
        await #expect(throws: PartError.jobMismatch) {
            try await service.save(draft, for: other.id, editing: first.id)
        }
        await #expect(throws: PartError.linkMismatch) {
            try await service.save(draft, for: other.id, editing: nil)
        }
        await #expect(throws: PartError.missingRecord) {
            try await service.save(draft, for: job.id, editing: UUID())
        }
        await #expect(throws: JobError.missingRecord) {
            try await service.save(PartFixture.draft(), for: UUID(), editing: nil)
        }
        var duplicate = PartDraft(part: first)
        duplicate.links += duplicate.links
        await #expect(throws: PartError.linkMismatch) {
            try await service.save(duplicate, for: job.id, editing: first.id)
        }
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: """
                    CREATE TRIGGER failPartLink BEFORE INSERT ON partLink
                    WHEN NEW.url LIKE '%failed%' BEGIN SELECT RAISE(ABORT, 'fixture disk failure'); END
                    """)
        }
        var edit = PartDraft(part: first)
        edit.description = "Changed description"
        edit.links = [PartLinkDraft(url: "https://example.org/failed")]
        await #expect(throws: DatabaseError.self) {
            try await service.save(edit, for: job.id, editing: first.id)
        }
        await #expect(throws: DatabaseError.self) {
            try await service.save(edit, for: job.id, editing: nil)
        }
        #expect(try await coordinator.read(PartQueries.fetchAll) == [first])
        try await coordinator.mutate { db, _, _ in try db.execute(sql: "DROP TRIGGER failPartLink")
        }
        let saved = try await service.save(edit, for: job.id, editing: first.id)
        #expect(saved.links.count == 1 && saved.links.first?.url == edit.links.first?.url)
        #expect(try await coordinator.read { try PartLink.fetchAll($0) } == saved.links)
        try await coordinator.close()
    }

    @Test(arguments: [JobStage.completed, .cancelled])
    func closureRequiresPartsExplanationAndRejectsStaleWrites(stage: JobStage) async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        let saved = try await service.save(PartFixture.draft(), for: job.id, editing: nil)
        var closure = JobTransitionDraft(stage: stage)
        closure.outcome = "Inspection complete"
        closure.cancellationReason = "Owner declined repair"
        let jobs = JobService(coordinator: coordinator)
        await #expect(throws: JobValidationError.self) {
            try await jobs.transition(job.id, using: closure)
        }
        closure.unfinishedPartsReason = "Owner will source this part separately"
        try await JobTaskFixture.failEvents(coordinator)
        await #expect(throws: DatabaseError.self) {
            try await jobs.transition(job.id, using: closure)
        }
        #expect(try await coordinator.read(JobQueries.fetchAll) == [job])
        try await coordinator.mutate { db, _, _ in try db.execute(sql: "DROP TRIGGER failTaskEvent")
        }
        let closed = try await jobs.transition(job.id, using: closure)
        #expect(closed.unfinishedPartsReason == closure.unfinishedPartsReason)
        #expect(
            try await coordinator.read(ActivityQueries.fetchAll).last?.nextValue
                == .job(JobStageValue(job: closed)))
        await #expect(throws: JobError.closedJob) {
            try await service.save(PartFixture.draft(), for: job.id, editing: nil)
        }
        await #expect(throws: JobError.closedJob) {
            try await service.save(PartFixture.draft(), for: job.id, editing: saved.id)
        }
        #expect(try await coordinator.read(PartQueries.fetchAll) == [saved])
        let reopened = try await jobs.reopen(job.id, using: JobTransitionDraft(stage: .inProgress))
        #expect(reopened.unfinishedPartsReason == nil)
        var edit = PartDraft(part: saved)
        edit.quantity = "3"
        #expect(try await service.save(edit, for: job.id, editing: saved.id).record.quantity == 3)
        try await coordinator.close()
    }

    @Test
    func migrationPreservesExistingRecordsAndOriginals() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        let before = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let task = try await JobTaskService(coordinator: coordinator).save(
            JobTaskFixture.draft(.done), for: job.id, editing: nil)
        let events = try await coordinator.read(ActivityQueries.fetchAll)
        try await coordinator.mutate { db, originals, _ in
            try Data("Original bytes".utf8).write(to: originals.appending(path: "evidence.bin"))
            try PartMigrationFixture.removeParts(in: db)
        }
        try await coordinator.close()
        let reopened = fixture.coordinator()
        let after = try await reopened.open()
        #expect(after.generationID != before.generationID)
        #expect(try await reopened.read(JobQueries.fetchAll) == [job])
        #expect(try await reopened.read(JobTaskQueries.fetchAll) == [task])
        #expect(try await reopened.read(ActivityQueries.fetchAll) == events)
        #expect(try await reopened.read(PartQueries.fetchAll).isEmpty)
        #expect(
            try Data(
                contentsOf: LibraryFiles.generation(after.generationID, in: fixture.root).appending(
                    path: "originals/evidence.bin")) == Data("Original bytes".utf8))
        _ = try await PartService(coordinator: reopened).save(
            PartFixture.draft(), for: job.id, editing: nil)
        try await reopened.close()
    }
}

nonisolated enum PartFixture {
    static func draft() -> PartDraft {
        var draft = PartDraft()
        draft.description = "Setting lever spring Å時計"
        return draft
    }
}

nonisolated enum PartMigrationFixture {
    static func removeParts(in db: Database) throws {
        try db.drop(table: "partLink")
        try db.drop(table: "partRequirement")
        try db.execute(sql: "ALTER TABLE job DROP COLUMN unfinishedPartsReason")
        try db.execute(
            sql:
                "DELETE FROM grdb_migrations WHERE identifier IN ('v13-part-requirements', 'v14-supplier-options')"
        )
    }
}
