import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct PartSupplierServiceTests {
    @Test
    func supplierDetailsReuseLinksAndOneChoiceSurvivesRestart() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        var draft = PartFixture.draft()
        draft.manufacturerReference = "0012.3–Å/04"
        draft.links = [
            PartLinkDraft(url: "https://example.org/parts/0012?variant=A"),
            PartLinkDraft(url: "https://example.org/drawing#spring"),
            PartLinkDraft(url: "https://example.net/alternate"),
        ]
        let first = try await service.save(draft, for: job.id, editing: nil)
        var edit = PartDraft(part: first)
        edit.links[0].supplierName = "Supplier Å時計"
        edit.links[0].title = "Setting lever spring, caliber 123"
        edit.links[0].supplierStockCode = "000098–A/03"
        edit.links[0].notes = "Old stock. Ask about the package."
        edit.links[0].price = "000123456789012345678901234567890.12345678901234567890"
        edit.links[0].currency = " dkk "
        edit.links[2].supplierName = "Second supplier"
        edit.links[2].price = "12.3400"
        edit.links[2].currency = "EUR"
        edit.selectedLinkID = edit.links[2].id
        let saved = try await service.save(edit, for: job.id, editing: first.id)
        #expect(saved.links.map(\.id) == first.links.map(\.id))
        #expect(saved.links.map(\.url) == first.links.map(\.url))
        #expect(saved.links.map(\.createdAt) == first.links.map(\.createdAt))
        #expect(saved.links[1] == first.links[1])
        #expect(saved.links[0].supplierStockCode == "000098–A/03")
        #expect(saved.links[0].price == edit.links[0].price && saved.links[0].currency == "DKK")
        #expect(saved.links[2].price == "12.3400" && saved.links[2].currency == "EUR")
        #expect(saved.record.manufacturerReference == "0012.3–Å/04")
        #expect(saved.selectedLink?.id == saved.links[2].id)
        #expect(saved.links.filter(\.isSelected).count == 1)
        var switchChoice = PartDraft(part: saved)
        switchChoice.selectedLinkID = saved.links[0].id
        let switched = try await service.save(switchChoice, for: job.id, editing: saved.id)
        #expect(switched.selectedLink?.id == saved.links[0].id)
        #expect(switched.links.filter(\.isSelected).count == 1)
        #expect(
            try await service.save(PartDraft(part: switched), for: job.id, editing: switched.id)
                == switched)
        #expect(try await coordinator.read(JobQueries.fetchAll) == [job])
        #expect(try await coordinator.read(ActivityQueries.fetchAll).isEmpty)
        try await coordinator.close()
        let reopened = fixture.coordinator()
        _ = try await reopened.open()
        #expect(try await reopened.read(PartQueries.fetchAll) == [switched])
        try await reopened.close()
    }

    @Test
    func selectionOwnershipRemovalAndDatabaseUniqueness() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        var draft = PartFixture.draft()
        draft.links = [
            PartLinkDraft(url: "https://example.org/first"),
            PartLinkDraft(url: "https://example.org/second"),
        ]
        draft.selectedLinkID = draft.links[0].id
        let first = try await service.save(draft, for: job.id, editing: nil)
        var otherDraft = PartFixture.draft()
        otherDraft.links = [PartLinkDraft(url: "https://example.net/other")]
        let other = try await service.save(otherDraft, for: job.id, editing: nil)
        var invalid = PartDraft(part: first)
        invalid.selectedLinkID = other.links[0].id
        await #expect(throws: PartValidationError.self) {
            try await service.save(invalid, for: job.id, editing: first.id)
        }
        invalid.links.append(PartLinkDraft(link: other.links[0]))
        await #expect(throws: PartError.linkMismatch) {
            try await service.save(invalid, for: job.id, editing: first.id)
        }
        for sql in [
            "UPDATE partLink SET isSelected = 1 WHERE partID = '\(first.id.uuidString)'",
            "UPDATE partLink SET isSelected = 2 WHERE partID = '\(first.id.uuidString)'",
        ] {
            await #expect(throws: DatabaseError.self) {
                try await coordinator.mutate { db, _, _ in try db.execute(sql: sql) }
            }
        }
        var removal = PartDraft(part: first)
        removal.links.removeFirst()
        removal.selectedLinkID = nil
        let removed = try await service.save(removal, for: job.id, editing: first.id)
        #expect(removed.id == first.id && removed.selectedLink == nil && removed.links.count == 1)
        #expect(removed.links.first?.id == first.links[1].id)
        #expect(try await coordinator.read { try PartQueries.fetch(other.id, in: $0) } == other)
        removal = PartDraft(part: removed)
        removal.selectedLinkID = removed.links[0].id
        let selected = try await service.save(removal, for: job.id, editing: first.id)
        var clear = PartDraft(part: selected)
        clear.selectedLinkID = nil
        let cleared = try await service.save(clear, for: job.id, editing: first.id)
        #expect(cleared.links.count == 1 && cleared.selectedLink == nil)
        try await coordinator.close()
    }

    @Test
    func failedSelectionChangeRollsBackDetailsAndRemoval() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        var draft = PartFixture.draft()
        draft.links = [
            PartLinkDraft(url: "https://example.org/first"),
            PartLinkDraft(url: "https://example.org/second"),
        ]
        draft.selectedLinkID = draft.links[1].id
        let first = try await service.save(draft, for: job.id, editing: nil)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: """
                    CREATE TRIGGER failSupplier BEFORE UPDATE ON partLink
                    WHEN NEW.supplierName = 'Failed supplier' BEGIN SELECT RAISE(ABORT, 'fixture disk failure'); END
                    """)
        }
        var edit = PartDraft(part: first)
        edit.description = "Changed part"
        edit.links.removeLast()
        edit.links[0].supplierName = "Failed supplier"
        edit.links[0].price = "123.4500"
        edit.links[0].currency = "DKK"
        edit.selectedLinkID = edit.links[0].id
        await #expect(throws: DatabaseError.self) {
            try await service.save(edit, for: job.id, editing: first.id)
        }
        #expect(try await coordinator.read(PartQueries.fetchAll) == [first])
        try await coordinator.mutate { db, _, _ in try db.execute(sql: "DROP TRIGGER failSupplier")
        }
        let saved = try await service.save(edit, for: job.id, editing: first.id)
        #expect(saved.links.count == 1 && saved.selectedLink?.supplierName == "Failed supplier")
        try await coordinator.close()
    }

    @Test(arguments: [
        "-1", "+1", "1e3", "NaN", "∞", ".5", "1.", "1,20", "１２.３", "1.2.3", "0 1", "-0",
    ])
    func rejectsMalformedPricesWithoutChangingSavedData(price: String) async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        var draft = PartFixture.draft()
        draft.links = [PartLinkDraft(url: "https://example.org/part")]
        let first = try await service.save(draft, for: job.id, editing: nil)
        var invalid = PartDraft(part: first)
        invalid.links[0].price = price
        invalid.links[0].currency = "DKK"
        await #expect(throws: PartValidationError.self) {
            try await service.save(invalid, for: job.id, editing: first.id)
        }
        #expect(try await coordinator.read(PartQueries.fetchAll) == [first])
        try await coordinator.close()
    }

    @Test(arguments: ["", " ", "ZZZ", "US", "USDD", "123", "$", "€", "EU R"])
    func priceRequiresAValidCurrency(currency: String) async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        var draft = PartFixture.draft()
        draft.links = [PartLinkDraft(url: "https://example.org/part")]
        draft.links[0].price = "12.3400"
        draft.links[0].currency = currency
        await #expect(throws: PartValidationError.self) {
            try await PartService(coordinator: coordinator).save(draft, for: job.id, editing: nil)
        }
        #expect(try await coordinator.read(PartQueries.fetchAll).isEmpty)
        try await coordinator.close()
    }

    @Test
    func optionalPriceAndCurrencyAndDatabasePriceConstraints() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        var draft = PartFixture.draft()
        draft.links = [PartLinkDraft(url: "https://example.org/part")]
        draft.links[0].price = " \n "
        draft.links[0].currency = " \t "
        let empty = try await service.save(draft, for: job.id, editing: nil)
        #expect(empty.links[0].price == nil && empty.links[0].currency == nil)
        var edit = PartDraft(part: empty)
        edit.links[0].currency = "zzz"
        await #expect(throws: PartValidationError.self) {
            try await service.save(edit, for: job.id, editing: empty.id)
        }
        edit.links[0].currency = "eur"
        let currencyOnly = try await service.save(edit, for: job.id, editing: empty.id)
        #expect(currencyOnly.links[0].price == nil && currencyOnly.links[0].currency == "EUR")
        edit = PartDraft(part: currencyOnly)
        edit.links[0].price = " 00.0000 "
        let zero = try await service.save(edit, for: job.id, editing: empty.id)
        #expect(zero.links[0].price == "00.0000")
        for sql in [
            "UPDATE partLink SET price = ''",
            "UPDATE partLink SET price = '-1'",
            "UPDATE partLink SET price = '1e3'",
            "UPDATE partLink SET price = '1.2.3'",
            "UPDATE partLink SET price = '.5'",
            "UPDATE partLink SET price = '1.'",
            "UPDATE partLink SET currency = NULL",
            "UPDATE partLink SET currency = 'EU'",
            "UPDATE partLink SET currency = 'eur'",
        ] {
            await #expect(throws: DatabaseError.self) {
                try await coordinator.mutate { db, _, _ in try db.execute(sql: sql) }
            }
        }
        #expect(try await coordinator.read(PartQueries.fetchAll) == [zero])
        var clear = PartDraft(part: zero)
        clear.links[0].price = ""
        clear.links[0].currency = ""
        let cleared = try await service.save(clear, for: job.id, editing: empty.id)
        #expect(cleared.links[0].price == nil && cleared.links[0].currency == nil)
        try await coordinator.close()
    }

    @Test
    func migrationPreservesURLOnlyLinksRecordsAndOriginals() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        let before = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let source = try fixture.source(type: .png)
        let photos = PhotoService(coordinator: coordinator)
        let photo = try await photos.importFiles([source], for: .job(job.id))[0].outcome.get()
        let watch = try await photos.setCover(photo.id, for: job.watchID)
        let original = try Data(contentsOf: source)
        let task = try await JobTaskService(coordinator: coordinator).save(
            JobTaskFixture.draft(.done), for: job.id, editing: nil)
        let events = try await coordinator.read(ActivityQueries.fetchAll)
        var draft = PartFixture.draft()
        draft.links = [
            PartLinkDraft(url: "https://example.org/part?code=0012"),
            PartLinkDraft(url: "https://example.org/drawing"),
        ]
        let part = try await PartService(coordinator: coordinator).save(
            draft, for: job.id, editing: nil)
        try await coordinator.mutate { db, originals, _ in
            try Data("Original bytes".utf8).write(to: originals.appending(path: "evidence.bin"))
            try db.execute(sql: "DROP INDEX partLink_selected")
            for column in [
                "title", "supplierName", "supplierStockCode", "notes", "isSelected", "price",
                "currency",
            ] {
                try db.execute(sql: "ALTER TABLE partLink DROP COLUMN \(column)")
            }
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = 'v14-supplier-options'")
        }
        try await coordinator.close()
        let reopened = LibraryCoordinator(root: fixture.root)
        let after = try await reopened.open()
        #expect(after.generationID != before.generationID)
        #expect(try await reopened.read(PartQueries.fetchAll) == [part])
        #expect(try await reopened.read(JobQueries.fetchAll) == [job])
        #expect(try await reopened.read(JobTaskQueries.fetchAll) == [task])
        #expect(try await reopened.read(ActivityQueries.fetchAll) == events)
        #expect(try await reopened.read(WatchQueries.fetchAll) == [watch])
        #expect(try await reopened.read(PhotoQueries.fetchAll) == [photo])
        #expect(try Data(contentsOf: await reopened.originalURL(for: photo.asset.id)) == original)
        #expect(
            try Data(
                contentsOf: LibraryFiles.generation(after.generationID, in: fixture.root).appending(
                    path: "originals/evidence.bin")) == Data("Original bytes".utf8))
        try await reopened.close()
    }

    @Test(arguments: [JobStage.completed, .cancelled])
    func closedJobsRejectSupplierDetailsSelectionAndRemoval(stage: JobStage) async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        var draft = PartFixture.draft()
        draft.links = [
            PartLinkDraft(url: "https://example.org/first"),
            PartLinkDraft(url: "https://example.org/second"),
        ]
        draft.selectedLinkID = draft.links[0].id
        let saved = try await service.save(draft, for: job.id, editing: nil)
        var closure = JobTransitionDraft(stage: stage)
        closure.outcome = "Inspection complete"
        closure.cancellationReason = "Owner declined repair"
        closure.unfinishedPartsReason = "Owner will source this part"
        _ = try await JobService(coordinator: coordinator).transition(job.id, using: closure)
        var details = PartDraft(part: saved)
        details.links[0].supplierName = "Stale supplier"
        details.links[0].price = "12.3400"
        details.links[0].currency = "DKK"
        var selection = PartDraft(part: saved)
        selection.selectedLinkID = saved.links[1].id
        var removal = PartDraft(part: saved)
        removal.links.removeFirst()
        removal.selectedLinkID = nil
        for edit in [details, selection, removal] {
            await #expect(throws: JobError.closedJob) {
                try await service.save(edit, for: job.id, editing: saved.id)
            }
        }
        #expect(try await coordinator.read(PartQueries.fetchAll) == [saved])
        try await coordinator.close()
    }
}
