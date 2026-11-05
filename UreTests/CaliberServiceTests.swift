import Foundation
import GRDB
import Synchronization
import Testing

@testable import Ure

nonisolated struct CaliberServiceTests {
    @Test
    func newCaliberHasOnlyItsNameAndEachFactSavesOnItsOwn() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = Mutex(created)
        let coordinator = fixture.coordinator(
            dependencies: LibraryDependencies(now: { clock.withLock { $0 } }))
        _ = try await coordinator.open()
        let service = CaliberService(coordinator: coordinator)
        let caliber = try await service.create()
        #expect(caliber.designation == "New Caliber" && caliber.manufacturer == nil)
        #expect(caliber.winding == nil && caliber.beatRate == nil && caliber.jewelCount == nil)
        #expect(caliber.powerReserve == nil && caliber.liftAngle == nil)
        #expect(caliber.createdAt == created && caliber.updatedAt == created)

        let edited = created.addingTimeInterval(60)
        clock.withLock { $0 = edited }
        let facts: [CaliberFact] = [
            .name("  0012–Å/3  "), .maker(" Example maker "), .winding(.manual),
            .beatRate(18_000), .jewels(17), .powerReserve(40), .liftAngle(52.5),
        ]
        for fact in facts { _ = try await service.update(caliber.id, fact) }
        let saved = try #require(try await coordinator.read(CaliberQueries.fetchAll).first)
        #expect(saved.designation == "0012–Å/3" && saved.manufacturer == "Example maker")
        #expect(saved.winding == .manual && saved.beatRate == 18_000 && saved.jewelCount == 17)
        #expect(saved.powerReserve == 40 && saved.liftAngle == 52.5)
        #expect(saved.createdAt == created && saved.updatedAt == edited)

        let cleared = created.addingTimeInterval(120)
        clock.withLock { $0 = cleared }
        #expect(try await service.update(caliber.id, .beatRate(18_000)) == saved)
        let withoutMaker = try await service.update(caliber.id, .maker("  "))
        #expect(withoutMaker.manufacturer == nil && withoutMaker.updatedAt == cleared)
        _ = try await service.update(caliber.id, .winding(nil))
        try await coordinator.close()

        let reopened = fixture.coordinator()
        _ = try await reopened.open()
        let restarted = try #require(try await reopened.read(CaliberQueries.fetchAll).first)
        #expect(restarted.winding == nil && restarted.manufacturer == nil)
        #expect(restarted.beatRate == 18_000)
        #expect(
            try await reopened.read { try SearchQueries.fetch("0012–å", in: $0) }.map(\.recordID)
                == [caliber.id])
        try await reopened.close()
    }

    @Test
    func invalidFactsAreRejectedAndChangeNothing() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let service = CaliberService(coordinator: coordinator)
        let caliber = try await service.create(named: "Test caliber")
        let invalid: [CaliberFact] = [
            .name(" \n "), .beatRate(0), .beatRate(-1), .liftAngle(0), .jewels(-1),
            .powerReserve(.infinity), .beatRate(.nan),
        ]
        for fact in invalid {
            await #expect(throws: CaliberValidationError.self) {
                try await service.update(caliber.id, fact)
            }
        }
        #expect(try await service.update(caliber.id, .jewels(0)).jewelCount == 0)
        #expect(try await service.update(caliber.id, .powerReserve(0)).powerReserve == 0)
        await #expect(throws: CaliberValidationError.self) {
            try await service.create(named: "  ")
        }
        await #expect(throws: ArchiveError.missingRecord) {
            try await service.update(UUID(), .name("Missing"))
        }
        let calibers = try await coordinator.read(CaliberQueries.fetchAll)
        #expect(calibers.count == 1 && calibers.first?.designation == "Test caliber")
        try await coordinator.close()
    }

    @Test
    func sharedUpdatesReachEveryLinkedWatchAndClearingOneKeepsTheOther() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let service = CaliberService(coordinator: coordinator)
        let caliber = try await service.create(named: "0012")
        let watches = WatchService(coordinator: coordinator)
        let first = try await watches.make("First watch", caliberID: caliber.id)
        let second = try await watches.make("Second watch", caliberID: caliber.id)
        let renamed = try await service.update(caliber.id, .name("Corrected designation"))
        #expect(
            try await coordinator.read(WatchQueries.fetchAll).allSatisfy {
                $0.caliberID == renamed.id
            })
        _ = try await watches.update(first.id, .caliber(nil))
        let restored = try await coordinator.read(WatchQueries.fetchAll)
        #expect(restored.first { $0.id == first.id }?.caliberID == nil)
        #expect(restored.first { $0.id == second.id }?.caliberID == caliber.id)
        #expect(try await coordinator.read(CaliberQueries.fetchAll) == [renamed])
        try await coordinator.close()
    }

    @Test
    func serviceAndDatabaseRejectMissingCalibersWithoutPartialWrites() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let service = WatchService(coordinator: coordinator)
        let watch = try await service.make("Watch")
        await #expect(throws: WatchError.self) {
            try await service.update(watch.id, .caliber(UUID()))
        }
        #expect(try await coordinator.read(WatchQueries.fetchAll) == [watch])
        await #expect(throws: DatabaseError.self) {
            try await coordinator.mutate { db, _, _ in
                try db.execute(
                    sql: "UPDATE watch SET caliberID = ? WHERE id = ?",
                    arguments: [UUID().uuidString, watch.id.uuidString])
            }
        }
        let caliber = try await CaliberService(coordinator: coordinator).create(
            named: "Linked caliber")
        _ = try await service.update(watch.id, .caliber(caliber.id))
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
