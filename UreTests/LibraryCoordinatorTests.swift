import CryptoKit
import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct LibraryCoordinatorTests {
    @Test
    func firstLaunchAndReopenKeepIdentityAndRows() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root, migrator: fixture.migrator)
        let first = try await coordinator.open()
        let repeated = try await coordinator.open()
        #expect(first == repeated)
        try await coordinator.mutate { db, _, _ in
            try db.execute(sql: "INSERT INTO fixtureRows VALUES (1, '0012–Å')")
        }
        try await coordinator.close()

        let reopened = LibraryCoordinator(root: fixture.root, migrator: fixture.migrator)
        #expect(try await reopened.open() == first)
        #expect(
            try await reopened.read { db in
                try String.fetchOne(db, sql: "SELECT value FROM fixtureRows WHERE id = 1")
            } == "0012–Å")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: fixture.generations.path).count == 1
        )
        #expect(!FileManager.default.fileExists(atPath: fixture.recovery.path))
        try await reopened.close()
    }

    @Test
    func injectedClockAndIDsReachLibraryAndMutations() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let dependencies = LibraryDependencies(makeID: { id }, now: { date })
        let coordinator = LibraryCoordinator(root: fixture.root, dependencies: dependencies)
        let info = try await coordinator.open()
        #expect(info.generationID == id)
        #expect(info.manifest.libraryID == id)
        #expect(info.manifest.createdAt == date)
        let values = try await coordinator.mutate { _, _, sources in
            (sources.makeID(), sources.now())
        }
        #expect(values.0 == id)
        #expect(values.1 == date)
        try await coordinator.close()
    }

    @Test
    func foreignKeysAndFailedMutationsPreserveCommittedRows() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root, migrator: fixture.migrator)
        _ = try await coordinator.open()
        #expect(
            try await coordinator.read { try Int.fetchOne($0, sql: "PRAGMA foreign_keys") } == 1)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: "CREATE TABLE fixtureChildren (parentID REFERENCES fixtureRows(id))")
            try db.execute(sql: "INSERT INTO fixtureRows VALUES (1, 'saved')")
        }
        await #expect(throws: DatabaseError.self) {
            try await coordinator.mutate { db, _, _ in
                try db.execute(sql: "UPDATE fixtureRows SET value = 'unsaved'")
                try db.execute(sql: "INSERT INTO fixtureChildren VALUES (99)")
            }
        }
        #expect(
            try await coordinator.read {
                try String.fetchOne($0, sql: "SELECT value FROM fixtureRows")
            }
                == "saved")
        #expect(
            try await coordinator.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM fixtureChildren")
            } == 0)
        try await coordinator.close()
    }

    @Test
    func snapshotsContainCommittedDatabaseAndUnchangedOriginals() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root, migrator: fixture.migrator)
        let info = try await coordinator.open()
        let bytes = try fixture.png()
        try await coordinator.mutate { db, originals, _ in
            try db.execute(sql: "INSERT INTO fixtureRows VALUES (1, 'snapshot row')")
            let folder = originals.appending(path: "nested")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try bytes.write(to: folder.appending(path: "original.png"))
        }
        let snapshot = try await coordinator.createSnapshot()
        let snapshotDatabase = try fixture.database(in: snapshot.directory, readonly: true)
        #expect(
            try fixture.read(snapshotDatabase) {
                try String.fetchOne($0, sql: "SELECT value FROM fixtureRows")
            } == "snapshot row")
        #expect(
            try LibraryFiles.read(
                LibraryManifest.self, from: snapshot.directory.appending(path: "manifest.json"))
                == info.manifest)
        #expect(
            try Data(
                contentsOf: snapshot.directory.appending(path: "originals/nested/original.png"))
                == bytes)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(
            snapshot.files.contains(
                SnapshotFile(
                    path: "originals/nested/original.png", byteCount: Int64(bytes.count),
                    sha256: digest)
            ))
        let savedManifest = try LibraryFiles.read(
            SnapshotManifest.self, from: snapshot.directory.appending(path: "snapshot.json"))
        #expect(savedManifest.files == snapshot.files)
        #expect(savedManifest.createdAt == snapshot.createdAt)
        try snapshotDatabase.close()
        try await coordinator.close()
        try FileManager.default.removeItem(at: fixture.generations)
        let independentDatabase = try fixture.database(in: snapshot.directory, readonly: true)
        #expect(
            try fixture.read(independentDatabase) {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM fixtureRows")
            } == 1)
        try independentDatabase.close()
    }

    @Test
    func validMigrationChangesGenerationAndKeepsRecoveryCopy() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let old = LibraryCoordinator(root: fixture.root, migrator: fixture.migrator)
        let original = try await old.open()
        let bytes = try fixture.png()
        try await old.mutate { db, originals, _ in
            try db.execute(sql: "INSERT INTO fixtureRows VALUES (1, 'before upgrade')")
            try bytes.write(to: originals.appending(path: "original.png"))
        }
        try await old.close()
        var migrator = fixture.migrator
        migrator.registerMigration("v3-add-detail") { db in
            try db.execute(sql: "ALTER TABLE fixtureRows ADD COLUMN detail TEXT")
        }
        let upgraded = LibraryCoordinator(root: fixture.root, migrator: migrator)
        let current = try await upgraded.open()
        #expect(current.generationID != original.generationID)
        #expect(current.manifest == original.manifest)
        #expect(
            try await upgraded.read {
                try String.fetchOne($0, sql: "SELECT value FROM fixtureRows")
            } == "before upgrade")
        #expect(try await upgraded.read { try $0.columns(in: "fixtureRows").count } == 3)
        #expect(
            try Data(
                contentsOf: LibraryFiles.generation(current.generationID, in: fixture.root)
                    .appending(path: "originals/original.png")) == bytes)
        let recoveryDirectories = try FileManager.default.contentsOfDirectory(
            at: fixture.recovery, includingPropertiesForKeys: nil)
        #expect(recoveryDirectories.count == 1)
        let recovery = try #require(recoveryDirectories.first)
        let recoveryDatabase = try fixture.database(in: recovery, readonly: true)
        #expect(try fixture.read(recoveryDatabase) { try $0.columns(in: "fixtureRows").count } == 2)
        try recoveryDatabase.close()
        let preserved = try fixture.database(
            in: LibraryFiles.generation(original.generationID, in: fixture.root), readonly: true)
        #expect(try fixture.read(preserved) { try $0.columns(in: "fixtureRows").count } == 2)
        try preserved.close()
        try await upgraded.close()
        let reopened = LibraryCoordinator(root: fixture.root, migrator: migrator)
        #expect(try await reopened.open() == current)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: fixture.recovery.path).count == 1)
        try await reopened.close()
    }

    @Test
    func failedUpgradePreservesAllOldRowsEvenAfterAnEarlierMigrationSucceeded() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let old = LibraryCoordinator(root: fixture.root, migrator: fixture.migrator)
        let original = try await old.open()
        try await old.mutate { db, _, _ in
            try db.execute(sql: "INSERT INTO fixtureRows VALUES (1, 'keep this row')")
        }
        try await old.close()
        let pointerBefore = try Data(contentsOf: fixture.pointer)
        var migrator = fixture.migrator
        migrator.registerMigration("v3-rewrite") { db in
            try db.execute(sql: "UPDATE fixtureRows SET value = 'changed by first migration'")
        }
        migrator.registerMigration("v4-failure") { db in
            try db.execute(sql: "DELETE FROM fixtureRows")
            throw FixtureFailure.expected
        }
        let upgraded = LibraryCoordinator(root: fixture.root, migrator: migrator)
        await #expect(throws: FixtureFailure.expected) { try await upgraded.open() }
        #expect(try Data(contentsOf: fixture.pointer) == pointerBefore)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: fixture.generations.path).count == 1
        )
        let reopened = LibraryCoordinator(root: fixture.root, migrator: fixture.migrator)
        #expect(try await reopened.open() == original)
        #expect(
            try await reopened.read {
                try String.fetchOne($0, sql: "SELECT value FROM fixtureRows")
            }
                == "keep this row")
        try await reopened.close()
        let recovery = try #require(
            FileManager.default.contentsOfDirectory(
                at: fixture.recovery, includingPropertiesForKeys: nil
            )
            .first)
        let recoveryDatabase = try fixture.database(in: recovery, readonly: true)
        #expect(
            try fixture.read(recoveryDatabase) {
                try String.fetchOne($0, sql: "SELECT value FROM fixtureRows")
            }
                == "keep this row")
        try recoveryDatabase.close()
    }

    @Test
    func snapshotFailurePreventsMigration() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let old = LibraryCoordinator(root: fixture.root, migrator: fixture.migrator)
        let original = try await old.open()
        try await old.close()
        try Data("blocks the recovery folder".utf8).write(to: fixture.recovery)
        var migrator = fixture.migrator
        migrator.registerMigration("v3-rewrite") { db in
            try db.execute(sql: "DROP TABLE fixtureRows")
        }
        let upgraded = LibraryCoordinator(root: fixture.root, migrator: migrator)
        await #expect(throws: (any Error).self) { try await upgraded.open() }
        let pointer = try LibraryFiles.read(ActiveLibrary.self, from: fixture.pointer)
        #expect(pointer.generationID == original.generationID)
        let database = try fixture.database(
            in: LibraryFiles.generation(original.generationID, in: fixture.root), readonly: true)
        #expect(try fixture.read(database) { try $0.tableExists("fixtureRows") })
        #expect(
            try fixture.read(database) {
                try String.fetchSet($0, sql: "SELECT identifier FROM grdb_migrations")
            }
                == Set(fixture.migrator.migrations))
        try database.close()
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: fixture.generations.path).count == 1
        )
    }

    @Test
    func newerSchemaStaysUnchanged() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        var futureMigrator = fixture.migrator
        futureMigrator.registerMigration("v99-future") { db in
            try db.execute(sql: "ALTER TABLE fixtureRows ADD COLUMN futureValue TEXT")
        }
        let future = LibraryCoordinator(root: fixture.root, migrator: futureMigrator)
        let original = try await future.open()
        try await future.close()
        let databaseURL = LibraryFiles.database(
            in: LibraryFiles.generation(original.generationID, in: fixture.root))
        let bytesBefore = try Data(contentsOf: databaseURL)
        let pointerBefore = try Data(contentsOf: fixture.pointer)
        let older = LibraryCoordinator(root: fixture.root, migrator: fixture.migrator)
        await #expect(throws: LibraryError.unsupportedSchema) { try await older.open() }
        #expect(try Data(contentsOf: databaseURL) == bytesBefore)
        #expect(try Data(contentsOf: fixture.pointer) == pointerBefore)
        #expect(!FileManager.default.fileExists(atPath: fixture.recovery.path))
    }

    @Test(arguments: ["database", "manifest", "pointer", "missing database", "missing pointer"])
    func damagedLibrariesNeverBecomeEmptyReplacements(damage: String) async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        let original = try await coordinator.open()
        try await coordinator.close()
        let directory = LibraryFiles.generation(original.generationID, in: fixture.root)
        let databaseURL = LibraryFiles.database(in: directory)
        let invalid = Data("not a valid library".utf8)
        switch damage {
        case "database":
            try invalid.write(to: databaseURL)
        case "manifest":
            try invalid.write(to: directory.appending(path: "manifest.json"))
        case "pointer":
            try invalid.write(to: fixture.pointer)
        case "missing database":
            try FileManager.default.removeItem(at: databaseURL)
        default:
            try FileManager.default.removeItem(at: fixture.pointer)
        }
        let failed = LibraryCoordinator(root: fixture.root)
        await #expect(throws: (any Error).self) { try await failed.open() }
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: fixture.generations.path).count == 1
        )
        if damage == "database" {
            #expect(try Data(contentsOf: databaseURL) == invalid)
        }
        if damage == "missing database" {
            #expect(!FileManager.default.fileExists(atPath: databaseURL.path))
        }
        if damage == "missing pointer" {
            #expect(!FileManager.default.fileExists(atPath: fixture.pointer.path))
        }
    }

    @Test
    func unsupportedStorageFormatStaysUnchanged() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        let original = try await coordinator.open()
        try await coordinator.close()
        let manifestURL = LibraryFiles.generation(original.generationID, in: fixture.root)
            .appending(path: "manifest.json")
        try LibraryFiles.write(
            LibraryManifest(
                formatVersion: 99, libraryID: original.manifest.libraryID,
                createdAt: original.manifest.createdAt), to: manifestURL)
        let bytes = try Data(contentsOf: manifestURL)
        let failed = LibraryCoordinator(root: fixture.root)
        await #expect(throws: LibraryError.unsupportedFormat(99)) { try await failed.open() }
        #expect(try Data(contentsOf: manifestURL) == bytes)
    }

    @Test
    func cancelledSnapshotPublishesNothingAndKeepsLibraryUsable() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        let original = try await coordinator.open()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await coordinator.createSnapshot()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await coordinator.open() == original)
        #expect(!FileManager.default.fileExists(atPath: fixture.recovery.path))
        try await coordinator.close()
    }

    @Test
    func symbolicLinkInOriginalsPreventsSnapshotAndUpgrade() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let old = LibraryCoordinator(root: fixture.root, migrator: fixture.migrator)
        let original = try await old.open()
        let fileOutsideOriginals = fixture.root.appending(path: "outside-originals.bin")
        try Data("outside original store".utf8).write(to: fileOutsideOriginals)
        try await old.mutate { _, originals, _ in
            try FileManager.default.createSymbolicLink(
                at: originals.appending(path: "linked-file.bin"),
                withDestinationURL: fileOutsideOriginals)
        }
        let error = LibraryError.invalidLibrary("The original file store contains a symbolic link.")
        await #expect(throws: error) { try await old.createSnapshot() }
        try await old.close()
        var migrator = fixture.migrator
        migrator.registerMigration("v3-delete-rows") { db in
            try db.execute(sql: "DROP TABLE fixtureRows")
        }
        let upgraded = LibraryCoordinator(root: fixture.root, migrator: migrator)
        await #expect(throws: error) { try await upgraded.open() }
        let pointer = try LibraryFiles.read(ActiveLibrary.self, from: fixture.pointer)
        #expect(pointer.generationID == original.generationID)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.recovery.path).isEmpty)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: fixture.generations.path).count == 1
        )
        #expect(try Data(contentsOf: fileOutsideOriginals) == Data("outside original store".utf8))
    }

    @Test
    func snapshotGateKeepsDatabaseAndOriginalsConsistentDuringConcurrentMutations() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root, migrator: fixture.migrator)
        _ = try await coordinator.open()
        let snapshots = try await withThrowingTaskGroup(of: LibrarySnapshot?.self) { group in
            for index in 1...12 {
                group.addTask {
                    try await coordinator.mutate { db, originals, _ in
                        try Data("original \(index)".utf8).write(
                            to: originals.appending(path: "\(index).bin"))
                        try db.execute(
                            sql: "INSERT INTO fixtureRows VALUES (?, ?)",
                            arguments: [index, "original \(index)"])
                    }
                    return nil
                }
                group.addTask { try await coordinator.createSnapshot() }
            }
            var results: [LibrarySnapshot] = []
            for try await snapshot in group {
                if let snapshot { results.append(snapshot) }
            }
            return results
        }
        #expect(snapshots.count == 12)
        for snapshot in snapshots {
            let database = try fixture.database(in: snapshot.directory, readonly: true)
            let rowCount = try fixture.read(database) {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM fixtureRows")
            }
            let originalCount = try FileManager.default.contentsOfDirectory(
                atPath: LibraryFiles.originals(in: snapshot.directory).path
            ).count
            #expect(rowCount == originalCount)
            let rows = try fixture.read(database) {
                try Row.fetchAll($0, sql: "SELECT id, value FROM fixtureRows")
            }
            for row in rows {
                let id: Int = row["id"]
                let value: String = row["value"]
                #expect(
                    try Data(contentsOf: snapshot.directory.appending(path: "originals/\(id).bin"))
                        == Data(value.utf8))
            }
            try database.close()
        }
        try await coordinator.close()
    }

    @Test
    func databaseWorkDoesNotRunOnMainThread() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        #expect(try await coordinator.read { _ in !Thread.isMainThread })
        #expect(try await coordinator.mutate { _, _, _ in !Thread.isMainThread })
        try await coordinator.close()
        await #expect(throws: LibraryError.notOpen) { try await coordinator.read { _ in 1 } }
        await #expect(throws: LibraryError.notOpen) {
            try await coordinator.mutate { _, _, _ in 1 }
        }
        await #expect(throws: LibraryError.notOpen) { try await coordinator.createSnapshot() }
    }
}

nonisolated private enum FixtureFailure: Error {
    case expected
}

nonisolated private struct LibraryFixture: Sendable {
    let root = URL.temporaryDirectory.appending(path: "UreTests/\(UUID().uuidString)")

    var pointer: URL { root.appending(path: "active-library.json") }
    var generations: URL { root.appending(path: "generations") }
    var recovery: URL { root.appending(path: "recovery") }

    var migrator: DatabaseMigrator {
        var migrator = LibrarySchema.migrator
        migrator.registerMigration("v2-fixture-rows") { db in
            try db.execute(
                sql: "CREATE TABLE fixtureRows (id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
        }
        return migrator
    }

    func database(in directory: URL, readonly: Bool) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.readonly = readonly
        return try DatabaseQueue(
            path: LibraryFiles.database(in: directory).path, configuration: configuration)
    }

    func read<Value>(_ database: DatabaseQueue, _ query: (Database) throws -> Value) throws -> Value
    {
        try database.read(query)
    }

    func png() throws -> Data {
        try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+afo8AAAAASUVORK5CYII="
            ))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
