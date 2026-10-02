import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct ReferenceServiceTests {
    @Test(arguments: [
        "https://example.org/manual.pdf?version=2#page=3",
        "http://localhost:8080/0012", "HTTPS://example.org/%E6%99%82%E8%A8%88",
        "https://example.org/a%20b", "  https://example.org/reference\n",
    ])
    func acceptsCompleteHTTPAndHTTPSURLs(text: String) throws {
        var draft = ReferenceFixture.draft
        draft.sourceURL = text
        let saved = try draft.record(
            id: UUID(), owner: .watch(UUID()), createdAt: Date(), updatedAt: Date())
        #expect(saved.sourceURL == text.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(ReferenceDraft.parsedURL(saved.sourceURL) != nil)
    }

    @Test(arguments: [
        "", "example.org/manual", "/relative", "//example.org/manual", "https:manual",
        "http://", "https://?query=1", "file:///tmp/manual.pdf", "javascript:alert(1)",
        "data:text/html,hello", "mailto:bench@example.org", "ftp://example.org/manual",
        "https://example.org/a b", "https://example.org/%ZZ", "https://example.org/\nmanual",
    ])
    func rejectsInvalidURLsAndForbiddenSchemes(text: String) {
        #expect(ReferenceDraft.parsedURL(text) == nil)
        var draft = ReferenceFixture.draft
        draft.sourceURL = text
        #expect(throws: ReferenceValidationError.self) {
            try draft.record(
                id: UUID(), owner: .watch(UUID()), createdAt: Date(), updatedAt: Date())
        }
    }

    @Test
    func severalLinksInEveryScopePreserveSourceContextAfterRestart() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { clock }))
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let service = ReferenceService(
            coordinator: coordinator,
            openBrowser: { _ in
                Issue.record("Saving must not open a browser")
                return false
            })
        var saved: [LibraryItem] = []
        for owner in owners {
            for number in 1...2 {
                var draft = ReferenceFixture.draft
                draft.title = "  Technical reference \(number)  "
                draft.sourceURL += "?reference=\(number)"
                draft.sourceDescription = "  Maker's bulletin – Å時計\nRevision 0012  "
                draft.notes = String(
                    repeating: "  Å 🔧 e\u{301}\n<script>plain text</script>\n", count: 1000)
                let item = try await service.save(draft, for: owner, editing: nil)
                #expect(item.belongs(to: owner))
                #expect(item.kind == .link)
                #expect(item.title == "Technical reference \(number)")
                #expect(item.sourceURL == draft.sourceURL)
                #expect(item.sourceDescription == draft.sourceDescription)
                #expect(item.notes == draft.notes)
                #expect(item.createdAt == clock)
                #expect(item.updatedAt == clock)
                saved.append(item)
            }
        }
        try await coordinator.close()
        let reopened = fixture.coordinator()
        _ = try await reopened.open()
        let restored = try await reopened.read(LibraryItemQueries.fetchAll)
        #expect(restored.count == 6)
        #expect(saved.allSatisfy { restored.contains($0) })
        for owner in owners { #expect(restored.filter { $0.belongs(to: owner) }.count == 2) }
        try await reopened.close()
    }

    @Test
    func editsPreserveIdentityOwnerAndCreationTime() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let old = fixture.coordinator(dependencies: LibraryDependencies(now: { created }))
        _ = try await old.open()
        let owner = try #require(try await ReferenceFixture.owners(old).first)
        let first = try await ReferenceService(coordinator: old).save(
            ReferenceFixture.draft, for: owner, editing: nil)
        try await old.close()
        let updated = created.addingTimeInterval(3600)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { updated }))
        _ = try await coordinator.open()
        var draft = ReferenceDraft(item: first)
        draft.title = "Corrected title"
        draft.sourceURL = "http://example.org/revised"
        draft.sourceDescription = "Corrected source"
        draft.notes = "Correction notes"
        let saved = try await ReferenceService(coordinator: coordinator).save(
            draft, for: owner, editing: first.id)
        #expect(saved.id == first.id)
        #expect(saved.belongs(to: owner))
        #expect(saved.createdAt == created)
        #expect(saved.updatedAt == updated)
        #expect(ReferenceDraft(item: saved) == draft)
        #expect(try await coordinator.read(LibraryItemQueries.fetchAll) == [saved])
        try await coordinator.close()
    }

    @Test
    func ownershipConstraintsAndServiceRejectInvalidWrites() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let service = ReferenceService(coordinator: coordinator)
        let saved = try await service.save(ReferenceFixture.draft, for: owners[0], editing: nil)
        for sql in [
            "UPDATE libraryItem SET watchID = NULL",
            "UPDATE libraryItem SET jobID = (SELECT id FROM job LIMIT 1)",
            "UPDATE libraryItem SET caliberID = (SELECT id FROM caliber LIMIT 1)",
            "UPDATE libraryItem SET watchID = NULL, jobID = (SELECT id FROM job LIMIT 1), caliberID = (SELECT id FROM caliber LIMIT 1)",
            "UPDATE libraryItem SET jobID = (SELECT id FROM job LIMIT 1), caliberID = (SELECT id FROM caliber LIMIT 1)",
            "UPDATE libraryItem SET kind = 'Photo'", "UPDATE libraryItem SET title = ''",
            "UPDATE libraryItem SET watchID = 'MISSING'",
        ] {
            await #expect(throws: DatabaseError.self) {
                try await coordinator.mutate { db, _, _ in try db.execute(sql: sql) }
            }
        }
        for owner in [LibraryItemOwner.watch(UUID()), .job(UUID()), .caliber(UUID())] {
            await #expect(throws: (any Error).self) {
                try await service.save(ReferenceFixture.draft, for: owner, editing: nil)
            }
        }
        await #expect(throws: ReferenceError.ownerMismatch) {
            try await service.save(ReferenceFixture.draft, for: owners[2], editing: saved.id)
        }
        await #expect(throws: ReferenceError.missingRecord) {
            try await service.save(ReferenceFixture.draft, for: owners[0], editing: UUID())
        }
        var invalid = ReferenceFixture.draft
        invalid.sourceURL = "file:///tmp/manual.pdf"
        await #expect(throws: ReferenceValidationError.self) {
            try await service.save(invalid, for: owners[0], editing: saved.id)
        }
        #expect(try await coordinator.read(LibraryItemQueries.fetchAll) == [saved])
        try await coordinator.close()
    }

    @Test(arguments: [JobStage.completed, .cancelled])
    func closedJobReferencesStayReadableAndRejectWritesUntilReopened(stage: JobStage) async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        guard case .job(let jobID) = owners[1] else { throw NoteFixtureError() }
        let service = ReferenceService(
            coordinator: coordinator,
            openBrowser: { url in
                #expect(url.absoluteString == ReferenceFixture.draft.sourceURL)
                return true
            })
        let saved = try await service.save(ReferenceFixture.draft, for: owners[1], editing: nil)
        var closure = JobTransitionDraft(stage: stage)
        closure.outcome = "Serviced"
        closure.cancellationReason = "Owner declined"
        let jobs = JobService(coordinator: coordinator)
        _ = try await jobs.transition(jobID, using: closure)
        try await service.open(saved)
        var draft = ReferenceDraft(item: saved)
        draft.notes = "Changed"
        for id in [nil, saved.id] {
            await #expect(throws: JobError.closedJob) {
                try await service.save(draft, for: owners[1], editing: id)
            }
        }
        #expect(try await coordinator.read(LibraryItemQueries.fetchAll) == [saved])
        _ = try await service.save(draft, for: owners[0], editing: nil)
        _ = try await service.save(draft, for: owners[2], editing: nil)
        _ = try await jobs.reopen(jobID, using: JobTransitionDraft(stage: .planned))
        let edited = try await service.save(draft, for: owners[1], editing: saved.id)
        #expect(edited.notes == "Changed")
        try await coordinator.close()
    }

    @Test
    @MainActor
    func openingRevalidatesSavedURLAndReportsBrowserFailure() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let service = ReferenceService(coordinator: coordinator, openBrowser: { _ in false })
        let saved = try await service.save(ReferenceFixture.draft, for: owners[0], editing: nil)
        #expect(throws: ReferenceError.browserUnavailable) {
            try service.open(saved)
        }
        try await coordinator.mutate { db, _, _ in
            try db.execute(sql: "UPDATE libraryItem SET sourceURL = 'javascript:alert(1)'")
        }
        let invalid = try #require(try await coordinator.read(LibraryItemQueries.fetchAll).first)
        #expect(throws: ReferenceError.invalidURL) {
            try service.open(invalid)
        }
        try await coordinator.close()
    }

    @Test
    func forwardMigrationKeepsRecordsNotesHistoryAndOriginals() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let old = fixture.coordinator()
        let before = try await old.open()
        let owners = try await NoteFixture.owners(old)
        guard case .job(let jobID) = owners[1] else { throw NoteFixtureError() }
        _ = try await JobService(coordinator: old).transition(
            jobID, using: JobTransitionDraft(stage: .inProgress))
        var draft = NoteDraft()
        draft.title = "Existing research"
        let note = try await NoteService(coordinator: old).save(draft, for: owners[0], editing: nil)
        let watches = try await old.read(WatchQueries.fetchAll)
        let calibers = try await old.read(CaliberQueries.fetchAll)
        let jobs = try await old.read(JobQueries.fetchAll)
        let events = try await old.read(ActivityQueries.fetchAll)
        let bytes = Data("original evidence".utf8)
        try await old.mutate { db, originals, _ in
            try ReferenceMigrationFixture.removeLinks(in: db)
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
        #expect(try await upgraded.read(NoteQueries.fetchAll) == [note])
        #expect(try await upgraded.read(LibraryItemQueries.fetchAll).isEmpty)
        #expect(
            try Data(
                contentsOf: LibraryFiles.generation(after.generationID, in: fixture.root)
                    .appending(path: "originals/evidence.bin")) == bytes)
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.root.appending(path: "recovery").path
            ).count == 1)
        try await upgraded.close()
    }
}

nonisolated enum ReferenceMigrationFixture {
    static func removeLinks(in db: Database) throws {
        try db.execute(sql: "DROP TABLE libraryItem")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v7-library-links'")
    }
}

nonisolated enum ReferenceFixture {
    static var draft: ReferenceDraft {
        var draft = ReferenceDraft()
        draft.title = "Technical sheet"
        draft.sourceURL = "https://example.org/manual.pdf"
        return draft
    }

    static func owners(_ coordinator: LibraryCoordinator) async throws -> [LibraryItemOwner] {
        try await NoteFixture.owners(coordinator).map { owner in
            switch owner {
            case .watch(let id): .watch(id)
            case .job(let id): .job(id)
            case .caliber(let id): .caliber(id)
            }
        }
    }
}
