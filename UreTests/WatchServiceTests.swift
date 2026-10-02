import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct WatchServiceTests {
    @Test
    func nameOnlyAndCompleteWatchesSurviveRestart() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { date }))
        _ = try await coordinator.open()
        let service = WatchService(coordinator: coordinator)
        var minimal = WatchDraft()
        minimal.name = "  Bench watch  "
        let first = try await service.save(minimal, editing: nil)
        #expect(first.name == "Bench watch")
        #expect(first.brand == nil)
        #expect(first.serial == nil)
        #expect(first.caseDiameter == nil)
        #expect(first.lugWidth == nil)
        #expect(first.specificationNotes == nil)
        #expect(first.createdAt == date)
        #expect(first.updatedAt == date)
        let full = fixture.completeDraft
        let second = try await service.save(full, editing: nil, locale: Locale(identifier: "da_DK"))
        #expect(second.caseReference == "0012–Å/3")
        #expect(second.serial == "000042.7-A")
        #expect(second.caseDiameter == 36.5)
        #expect(second.lugWidth == 18)
        #expect(second.approximateYear == "circa 1960–1965")
        #expect(second.specificationNotes == full.specificationNotes)
        try await coordinator.close()
        let reopened = fixture.coordinator()
        _ = try await reopened.open()
        let records = try await reopened.read(WatchQueries.fetchAll)
        #expect(Set(records.map(\.id)) == [first.id, second.id])
        #expect(records.contains(first))
        #expect(records.contains(second))
        #expect(
            WatchDraft(watch: second, locale: Locale(identifier: "da_DK")).caseDiameter == "36,5")
        try await reopened.close()
    }

    @Test(arguments: ["0", "-1", "nan", "inf", "1e999", "18mm", "18,5"])
    func invalidDimensionsReportBothFieldsAndWriteNothing(value: String) async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        var draft = WatchDraft()
        draft.name = "Watch"
        draft.caseDiameter = value
        draft.lugWidth = value
        do {
            _ = try await WatchService(coordinator: coordinator).save(
                draft, editing: nil, locale: Locale(identifier: "en_US"))
            Issue.record("Invalid dimensions must fail")
        } catch let error as WatchValidationError {
            #expect(error.fields[.caseDiameter] != nil)
            #expect(error.fields[.lugWidth] != nil)
        }
        #expect(try await coordinator.read(WatchQueries.fetchAll).isEmpty)
        try await coordinator.close()
    }

    @Test
    func missingNameFailsAndDuplicateNamesRemainAllowed() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let service = WatchService(coordinator: coordinator)
        var draft = WatchDraft()
        draft.name = " \n "
        do {
            _ = try await service.save(draft, editing: nil)
            Issue.record("A blank name must fail")
        } catch let error as WatchValidationError {
            #expect(error.fields[.name] != nil)
        }
        draft.name = "Same name"
        draft.serial = "0000-1"
        draft.caseDiameter = "  "
        let first = try await service.save(draft, editing: nil)
        let second = try await service.save(draft, editing: nil)
        #expect(first.id != second.id)
        #expect(first.caseDiameter == nil)
        #expect(try await coordinator.read(WatchQueries.fetchAll).count == 2)
        try await coordinator.close()
    }

    @Test
    func editingKeepsIdentityCreationTimeAndUntouchedSpecifications() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let old = fixture.coordinator(dependencies: LibraryDependencies(now: { created }))
        _ = try await old.open()
        let record = try await WatchService(coordinator: old).save(
            fixture.completeDraft, editing: nil, locale: Locale(identifier: "da_DK"))
        try await old.close()
        let updated = created.addingTimeInterval(3600)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { updated }))
        _ = try await coordinator.open()
        var draft = WatchDraft(watch: record)
        draft.name = "Renamed watch"
        let saved = try await WatchService(coordinator: coordinator).save(draft, editing: record.id)
        #expect(saved.id == record.id)
        #expect(saved.createdAt == created)
        #expect(saved.updatedAt == updated)
        #expect(saved.name == draft.name)
        #expect(saved.serial == record.serial)
        #expect(saved.caseDiameter == record.caseDiameter)
        #expect(try await coordinator.read(WatchQueries.fetchAll) == [saved])
        try await coordinator.close()
    }

    @Test
    func anUnavailableEditDoesNotCreateANewWatch() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        var draft = WatchDraft()
        draft.name = "Stale edit"
        await #expect(throws: WatchError.self) {
            try await WatchService(coordinator: coordinator).save(draft, editing: UUID())
        }
        #expect(try await coordinator.read(WatchQueries.fetchAll).isEmpty)
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func observationPublishesCommittedEditsAndIgnoresFailedWrites() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let values = try await coordinator.watchValues()
        var iterator = values.makeAsyncIterator()
        #expect(try await iterator.next() == [])
        let service = WatchService(coordinator: coordinator)
        var draft = WatchDraft()
        draft.name = "First name"
        let first = try await service.save(draft, editing: nil)
        #expect(try await iterator.next() == [first])
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: """
                    CREATE TRIGGER failWatchUpdate BEFORE UPDATE ON watch
                    BEGIN SELECT RAISE(ABORT, 'fixture write failed'); END
                    """)
        }
        draft.name = "Failed name"
        await #expect(throws: DatabaseError.self) {
            try await service.save(draft, editing: first.id)
        }
        #expect(try await coordinator.read(WatchQueries.fetchAll) == [first])
        try await coordinator.mutate { db, _, _ in
            try db.execute(sql: "DROP TRIGGER failWatchUpdate")
        }
        draft.name = "Final name"
        let last = try await service.save(draft, editing: first.id)
        #expect(try await iterator.next() == [last])
        try await coordinator.close()
    }

    @Test
    func watchMigrationPreservesTheMetadataLibraryAndOriginals() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        var oldSchema = DatabaseMigrator()
        oldSchema.registerMigration("v1-library-metadata", foreignKeyChecks: .immediate) { db in
            try db.create(table: "libraryMetadata") { table in
                table.column("id", .text).primaryKey()
                table.column("createdAt", .double).notNull()
            }
        }
        let old = LibraryCoordinator(root: fixture.root, migrator: oldSchema)
        let before = try await old.open()
        let bytes = Data("original evidence".utf8)
        try await old.mutate { _, originals, _ in
            try bytes.write(to: originals.appending(path: "evidence.bin"))
        }
        try await old.close()
        let upgraded = fixture.coordinator()
        let after = try await upgraded.open()
        #expect(after.manifest == before.manifest)
        #expect(after.generationID != before.generationID)
        #expect(try await upgraded.read(WatchQueries.fetchAll).isEmpty)
        #expect(
            try Data(
                contentsOf: LibraryFiles.generation(after.generationID, in: fixture.root)
                    .appending(path: "originals/evidence.bin")) == bytes)
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.root.appending(path: "recovery").path
            )
            .count == 1)
        try await upgraded.close()
        let previous = LibraryCoordinator(root: fixture.root, migrator: oldSchema)
        await #expect(throws: LibraryError.unsupportedSchema) { try await previous.open() }
    }
}

nonisolated struct WatchFixture: Sendable {
    let root = URL.temporaryDirectory.appending(path: "UreTests/\(UUID().uuidString)")

    func coordinator(dependencies: LibraryDependencies = LibraryDependencies())
        -> LibraryCoordinator
    {
        LibraryCoordinator(root: root, dependencies: dependencies)
    }

    var completeDraft: WatchDraft {
        var draft = WatchDraft()
        draft.name = "Inherited watch"
        draft.brand = "Example maker"
        draft.model = "Å 001"
        draft.caseReference = "0012–Å/3"
        draft.serial = "000042.7-A"
        draft.approximateYear = "circa 1960–1965"
        draft.caseMaterial = "Steel"
        draft.caseDiameter = "36,5"
        draft.lugWidth = "18"
        draft.waterResistance = "3 atm (unverified)"
        draft.specificationNotes = "Unsigned dial.\nCheck the case back."
        return draft
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
