import Foundation
import GRDB
import Synchronization
import Testing

@testable import Ure

nonisolated struct WatchServiceTests {
    @Test
    func newWatchHasOnlyItsNameAndEachFactSavesOnItsOwn() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = Mutex(created)
        let coordinator = fixture.coordinator(
            dependencies: LibraryDependencies(now: { clock.withLock { $0 } }))
        _ = try await coordinator.open()
        let caliber = try await CaliberService(coordinator: coordinator).create(named: "552")
        let service = WatchService(coordinator: coordinator)
        let watch = try await service.create()
        #expect(watch.name == "New Watch" && watch.brand == nil && watch.caliberID == nil)
        #expect(watch.owner == nil && watch.contact == nil && watch.caseDiameter == nil)
        #expect(watch.createdAt == created && watch.updatedAt == created)

        let edited = created.addingTimeInterval(60)
        clock.withLock { $0 = edited }
        let facts: [WatchFact] = [
            .name("  Inherited watch  "), .brand(" Example maker "), .model("Å 001"),
            .reference("0012–Å/3"), .serial("000042.7-A"), .year("circa 1960–1965"),
            .caliber(caliber.id), .caseMaterial("Steel"), .diameter(36.5), .lugWidth(18),
            .owner(" Åse Øster "), .contact("No email; call +45 (00) 0012 / daytime"),
        ]
        for fact in facts { _ = try await service.update(watch.id, fact) }
        let saved = try #require(try await coordinator.read(WatchQueries.fetchAll).first)
        #expect(saved.name == "Inherited watch" && saved.brand == "Example maker")
        #expect(saved.model == "Å 001" && saved.caseReference == "0012–Å/3")
        #expect(saved.serial == "000042.7-A" && saved.approximateYear == "circa 1960–1965")
        #expect(saved.caliberID == caliber.id && saved.caseMaterial == "Steel")
        #expect(saved.caseDiameter == 36.5 && saved.lugWidth == 18)
        #expect(saved.owner == "Åse Øster")
        #expect(saved.contact == "No email; call +45 (00) 0012 / daytime")
        #expect(saved.createdAt == created && saved.updatedAt == edited)

        let cleared = created.addingTimeInterval(120)
        clock.withLock { $0 = cleared }
        #expect(try await service.update(watch.id, .serial("000042.7-A")) == saved)
        let withoutOwner = try await service.update(watch.id, .owner("  "))
        #expect(withoutOwner.owner == nil && withoutOwner.updatedAt == cleared)
        _ = try await service.update(watch.id, .caliber(nil))
        try await coordinator.close()

        let reopened = fixture.coordinator()
        _ = try await reopened.open()
        let restarted = try #require(try await reopened.read(WatchQueries.fetchAll).first)
        #expect(restarted.owner == nil && restarted.caliberID == nil)
        #expect(restarted.contact == saved.contact && restarted.serial == "000042.7-A")
        #expect(
            try await reopened.read { try SearchQueries.fetch("call +45", in: $0) }.map(
                \.recordID) == [watch.id])
        try await reopened.close()
    }

    @Test
    func invalidFactsAreRejectedAndChangeNothing() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let service = WatchService(coordinator: coordinator)
        let watch = try await service.create(named: "Bench watch")
        for fact in [
            WatchFact.name(" \n "), .diameter(0), .diameter(-1), .lugWidth(.nan),
            .lugWidth(.infinity),
        ] {
            await #expect(throws: WatchValidationError.self) {
                try await service.update(watch.id, fact)
            }
        }
        await #expect(throws: WatchError.self) {
            try await service.update(watch.id, .caliber(UUID()))
        }
        await #expect(throws: ArchiveError.missingRecord) {
            try await service.update(UUID(), .name("Stale edit"))
        }
        #expect(try await coordinator.read(WatchQueries.fetchAll) == [watch])
        let twin = try await service.create(named: "Bench watch")
        #expect(twin.id != watch.id)
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
        let first = try await service.create(named: "First name")
        #expect(try await iterator.next() == [first])
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: """
                    CREATE TRIGGER failWatchUpdate BEFORE UPDATE ON watch
                    BEGIN SELECT RAISE(ABORT, 'fixture write failed'); END
                    """)
        }
        await #expect(throws: DatabaseError.self) {
            try await service.update(first.id, .name("Failed name"))
        }
        #expect(try await coordinator.read(WatchQueries.fetchAll) == [first])
        try await coordinator.mutate { db, _, _ in
            try db.execute(sql: "DROP TRIGGER failWatchUpdate")
        }
        let last = try await service.update(first.id, .name("Final name"))
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

    func remove() { try? FileManager.default.removeItem(at: root) }

    // A watch with every identity and case fact, and the given caliber.
    static func completeWatch(
        _ coordinator: LibraryCoordinator, caliberID: UUID? = nil
    ) async throws -> WatchRecord {
        let service = WatchService(coordinator: coordinator)
        var watch = try await service.make(
            "Inherited watch", brand: "Example maker", caliberID: caliberID)
        for fact in [
            WatchFact.model("Å 001"), .reference("0012–Å/3"), .serial("000042.7-A"),
            .year("circa 1960–1965"), .caseMaterial("Steel"), .diameter(36.5), .lugWidth(18),
        ] {
            watch = try await service.update(watch.id, fact)
        }
        return watch
    }
}

extension WatchService {
    // Makes a watch the way the watch page does: ⌘N, then each fact on its own.
    nonisolated func make(
        _ name: String, brand: String? = nil, caliberID: UUID? = nil
    ) async throws -> WatchRecord {
        var watch = try await create(named: name)
        if let brand { watch = try await update(watch.id, .brand(brand)) }
        if let caliberID { watch = try await update(watch.id, .caliber(caliberID)) }
        return watch
    }
}
