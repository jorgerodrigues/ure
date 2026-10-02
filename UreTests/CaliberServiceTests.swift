import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct CaliberServiceTests {
    @Test
    func minimalAndCompleteCalibersSurviveRestartWithoutInventedValues() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { date }))
        _ = try await coordinator.open()
        let service = CaliberService(coordinator: coordinator)
        #expect(try await coordinator.read(CaliberQueries.fetchAll).isEmpty)
        var minimal = CaliberDraft()
        minimal.designation = "  0012–Å/3  "
        let first = try await service.save(minimal, editing: nil)
        #expect(first.designation == "0012–Å/3")
        #expect(first.manufacturer == nil)
        #expect(first.variant == nil)
        #expect(first.movementType == .unknown)
        #expect(first.beatRate == nil)
        #expect(first.jewelCount == nil)
        #expect(first.powerReserve == nil)
        #expect(first.liftAngle == nil)
        #expect(first.sourceNote == nil)
        #expect(first.createdAt == date)
        let second = try await service.save(
            completeDraft, editing: nil, locale: Locale(identifier: "da_DK"))
        #expect(second.variant == "0002-A")
        #expect(second.liftAngle == 52.5)
        try await coordinator.close()
        let reopened = fixture.coordinator()
        _ = try await reopened.open()
        let records = try await reopened.read(CaliberQueries.fetchAll)
        #expect(records.count == 2)
        #expect(records.contains(first))
        #expect(records.contains(second))
        #expect(
            CaliberDraft(caliber: second, locale: Locale(identifier: "da_DK")).liftAngle == "52,5")
        try await reopened.close()
    }

    @Test(arguments: ["-1", "nan", "inf", "1e999", "18 vph", "18,5"])
    func invalidNumbersReportFieldsAndCommitNothing(value: String) async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        var draft = CaliberDraft()
        draft.designation = "Test caliber"
        draft.beatRate = value
        draft.jewelCount = value
        draft.powerReserve = value
        draft.liftAngle = value
        do {
            _ = try await CaliberService(coordinator: coordinator).save(
                draft, editing: nil, locale: Locale(identifier: "en_US"))
            Issue.record("Invalid specifications must fail")
        } catch let error as CaliberValidationError {
            #expect(error.fields.count == 4)
        }
        #expect(try await coordinator.read(CaliberQueries.fetchAll).isEmpty)
        try await coordinator.close()
    }

    @Test
    func zeroIsAllowedForJewelCountAndPowerReserve() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let service = CaliberService(coordinator: coordinator)
        var draft = CaliberDraft()
        draft.designation = "Test caliber"
        draft.jewelCount = "0"
        draft.powerReserve = "0"
        draft.beatRate = "0"
        draft.liftAngle = "0"
        do {
            _ = try await service.save(draft, editing: nil)
            Issue.record("Zero beat rate and lift angle must fail")
        } catch let error as CaliberValidationError {
            #expect(Set(error.fields.keys) == [.beatRate, .liftAngle])
        }
        draft.beatRate = "  "
        draft.liftAngle = ""
        let saved = try await service.save(draft, editing: nil)
        #expect(saved.beatRate == nil)
        #expect(saved.liftAngle == nil)
        #expect(saved.jewelCount == 0)
        #expect(saved.powerReserve == 0)
        try await coordinator.close()
    }

    @Test
    func designationIsRequiredAndVariantsRemainSeparateWithoutUniquenessRules() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let service = CaliberService(coordinator: coordinator)
        var draft = CaliberDraft()
        draft.designation = " \n "
        do {
            _ = try await service.save(draft, editing: nil)
            Issue.record("A blank designation must fail")
        } catch let error as CaliberValidationError {
            #expect(error.fields[.designation] != nil)
        }
        draft.designation = "0012"
        draft.variant = "A/2"
        let first = try await service.save(draft, editing: nil)
        let second = try await service.save(draft, editing: nil)
        #expect(first.id != second.id)
        #expect(first.designation == "0012")
        #expect(first.variant == "A/2")
        #expect(try await coordinator.read(CaliberQueries.fetchAll).count == 2)
        await #expect(throws: CaliberError.self) {
            try await service.save(draft, editing: UUID())
        }
        try await coordinator.close()
    }

    @Test
    func sharedUpdatesAndClearingOneWatchPreserveOtherReferencesAfterRestart() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let old = fixture.coordinator(dependencies: LibraryDependencies(now: { created }))
        _ = try await old.open()
        let caliber = try await CaliberService(coordinator: old).save(
            completeDraft, editing: nil, locale: Locale(identifier: "da_DK"))
        let watches = WatchService(coordinator: old)
        var draft = WatchDraft()
        draft.name = "First watch"
        draft.caliberID = caliber.id
        let first = try await watches.save(draft, editing: nil)
        draft.name = "Second watch"
        let second = try await watches.save(draft, editing: nil)
        try await old.close()
        let updated = created.addingTimeInterval(3600)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { updated }))
        _ = try await coordinator.open()
        var edit = CaliberDraft(caliber: caliber)
        edit.designation = "Corrected designation"
        edit.sourceNote = "Corrected from the maker's technical sheet."
        let saved = try await CaliberService(coordinator: coordinator).save(
            edit, editing: caliber.id)
        #expect(saved.id == caliber.id)
        #expect(saved.createdAt == created)
        #expect(saved.updatedAt == updated)
        #expect(saved.variant == caliber.variant)
        let records = try await coordinator.read(WatchQueries.fetchAll)
        #expect(records.allSatisfy { $0.caliberID == saved.id })
        var clear = WatchDraft(watch: first)
        clear.caliberID = nil
        _ = try await WatchService(coordinator: coordinator).save(clear, editing: first.id)
        try await coordinator.close()
        let reopened = fixture.coordinator()
        _ = try await reopened.open()
        #expect(try await reopened.read(CaliberQueries.fetchAll) == [saved])
        let restored = try await reopened.read(WatchQueries.fetchAll)
        #expect(restored.first { $0.id == first.id }?.caliberID == nil)
        #expect(restored.first { $0.id == second.id }?.caliberID == caliber.id)
        try await reopened.close()
    }

    @Test
    func serviceAndDatabaseRejectMissingCalibersWithoutPartialWrites() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let service = WatchService(coordinator: coordinator)
        var draft = WatchDraft()
        draft.name = "Watch"
        let watch = try await service.save(draft, editing: nil)
        draft.caliberID = UUID()
        await #expect(throws: WatchError.self) { try await service.save(draft, editing: watch.id) }
        await #expect(throws: WatchError.self) { try await service.save(draft, editing: nil) }
        #expect(try await coordinator.read(WatchQueries.fetchAll) == [watch])
        await #expect(throws: DatabaseError.self) {
            try await coordinator.mutate { db, _, _ in
                try db.execute(
                    sql: "UPDATE watch SET caliberID = ? WHERE id = ?",
                    arguments: [UUID().uuidString, watch.id.uuidString])
            }
        }
        var caliberDraft = CaliberDraft()
        caliberDraft.designation = "Linked caliber"
        let caliber = try await CaliberService(coordinator: coordinator).save(
            caliberDraft, editing: nil)
        draft.caliberID = caliber.id
        _ = try await service.save(draft, editing: watch.id)
        await #expect(throws: DatabaseError.self) {
            try await coordinator.mutate { db, _, _ in
                try db.execute(
                    sql: "DELETE FROM caliber WHERE id = ?", arguments: [caliber.id.uuidString])
            }
        }
        #expect(try await coordinator.read(CaliberQueries.fetchAll) == [caliber])
        try await coordinator.close()
    }

    @Test
    func upgradingWatchLibraryPreservesRecordsAndOriginals() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let old = LibraryCoordinator(root: fixture.root, migrator: previousSchema)
        let before = try await old.open()
        let watchID = UUID()
        let bytes = Data("original evidence".utf8)
        try await old.mutate { db, originals, _ in
            try db.execute(
                sql: """
                    INSERT INTO watch (id, name, serial, caseDiameter, createdAt, updatedAt)
                    VALUES (?, 'Existing watch', '000042-A/7', 36.5, 1700000000, 1700000000)
                    """, arguments: [watchID.uuidString])
            try bytes.write(to: originals.appending(path: "evidence.bin"))
        }
        try await old.close()
        let upgraded = fixture.coordinator()
        let after = try await upgraded.open()
        #expect(after.manifest == before.manifest)
        #expect(after.generationID != before.generationID)
        let watch = try #require(try await upgraded.read(WatchQueries.fetchAll).first)
        #expect(watch.id == watchID)
        #expect(watch.serial == "000042-A/7")
        #expect(watch.caseDiameter == 36.5)
        #expect(watch.caliberID == nil)
        #expect(try await upgraded.read(CaliberQueries.fetchAll).isEmpty)
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

    private var completeDraft: CaliberDraft {
        var draft = CaliberDraft()
        draft.designation = "0012–Å/3"
        draft.manufacturer = "Example maker"
        draft.variant = "0002-A"
        draft.movementType = .manual
        draft.beatRate = "18000"
        draft.jewelCount = "17"
        draft.powerReserve = "40"
        draft.liftAngle = "52,5"
        draft.specificationNotes = "Fixture values only.\nDo not assume compatibility."
        draft.sourceNote = "Synthetic technical sheet, variant 0002-A."
        return draft
    }

    private var previousSchema: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-library-metadata", foreignKeyChecks: .immediate) { db in
            try db.create(table: "libraryMetadata") { table in
                table.column("id", .text).primaryKey()
                table.column("createdAt", .double).notNull()
            }
        }
        migrator.registerMigration("v2-watches", foreignKeyChecks: .immediate) { db in
            try db.create(table: "watch") { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull().check(sql: "length(trim(name)) > 0")
                for column in [
                    "brand", "model", "caseReference", "serial", "approximateYear", "caseMaterial",
                    "waterResistance", "specificationNotes",
                ] { table.column(column, .text) }
                table.column("caseDiameter", .double).check { $0 > 0 }
                table.column("lugWidth", .double).check { $0 > 0 }
                table.column("createdAt", .double).notNull()
                table.column("updatedAt", .double).notNull()
            }
        }
        return migrator
    }
}
