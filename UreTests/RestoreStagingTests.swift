import CryptoKit
import Darwin
import Foundation
import GRDB
import Synchronization
import Testing

@testable import Ure

nonisolated struct RestoreStagingTests {
    @Test
    func physicalFreeSpaceAllowsRestoreWhenImportantCapacityIsZero() throws {
        #expect(
            try RestoreFiles.availableCapacity(available: 124_661_760, important: 0) == 124_661_760)
        #expect(try RestoreFiles.availableCapacity(available: 0, important: 0) == 0)
        #expect(try RestoreFiles.availableCapacity(available: 0, important: 512) == 512)
        #expect(try RestoreFiles.availableCapacity(available: 512, important: nil) == 512)
        #expect(try RestoreFiles.availableCapacity(available: nil, important: 512) == 512)
    }

    @Test
    func unknownDiskCapacityRejectsRestore() {
        #expect(throws: RestoreError.self) {
            try RestoreFiles.availableCapacity(available: nil, important: nil)
        }
    }

    @Test
    func validPackageStagesAnIndependentGenerationWithoutActivation() async throws {
        let fixture = RestoreFixture()
        defer { fixture.files.remove() }
        let coordinator = LibraryCoordinator(root: fixture.files.root)
        let active = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        for owner in owners {
            let photo = try fixture.files.source(type: .heic)
            let pdf = try fixture.files.source(type: .pdf)
            _ = try #require(
                await PhotoService(coordinator: coordinator).importFiles([photo], for: owner).first
            )
            .outcome.get()
            _ = try #require(
                await DocumentService(coordinator: coordinator).importFiles([pdf], for: owner).first
            )
            .outcome.get()
        }
        let orphan = try await coordinator.importOriginal(
            from: fixture.files.source(type: .png), maximumByteCount: 1_000_000)
        _ = try await coordinator.exportBackup(to: fixture.package, applicationVersion: "fixture")
        let activeBytes = try fixture.capture()
        let watches = try await coordinator.read(WatchQueries.fetchAll)
        let assets = try await coordinator.read(FileAssetQueries.fetchAll)
        let result = try await coordinator.stageRestore(from: fixture.package)
        #expect(result.library.generationID != active.generationID)
        #expect(result.library.manifest == active.manifest)
        #expect(result.summary.counts["fileAsset"] == 7)
        #expect(result.summary.originalCount == 7)
        #expect(result.summary.appliedMigrations.isEmpty)
        #expect(try await coordinator.open() == active)
        let staged = LibraryFiles.generation(result.library.generationID, in: fixture.files.root)
        let reader = try RestoreDatabase.open(in: staged, readonly: true)
        #expect(try await reader.read(WatchQueries.fetchAll) == watches)
        #expect(try await reader.read(FileAssetQueries.fetchAll) == assets)
        try reader.close()
        for asset in assets {
            let original = try await coordinator.originalURL(for: asset.id)
            #expect(
                try Data(contentsOf: staged.appending(path: "originals/\(asset.storageKey)"))
                    == Data(contentsOf: original))
        }
        #expect(
            FileManager.default.fileExists(
                atPath: staged.appending(path: "originals/\(orphan.storageKey)").path))
        for (path, bytes) in activeBytes {
            #expect(try Data(contentsOf: fixture.files.root.appending(path: path)) == bytes)
        }
        #expect(!FileManager.default.fileExists(atPath: staged.appending(path: "backup.json").path))
        #expect(
            try fixture.generationNames() == [
                active.generationID.uuidString, result.library.generationID.uuidString,
            ])
        try FileManager.default.removeItem(at: fixture.package)
        #expect(try await coordinator.read(WatchQueries.fetchAll) == watches)
        try await coordinator.close()
    }

    @Test(arguments: RestoreDamage.allCases)
    func damagedPackagesKeepEveryActiveByteAndRemovePartialStaging(damage: RestoreDamage)
        async throws
    {
        let fixture = RestoreFixture()
        defer { fixture.files.remove() }
        let coordinator = LibraryCoordinator(root: fixture.files.root)
        _ = try await fixture.seed(coordinator)
        let before = try fixture.capture()
        let generations = try fixture.generationNames()
        try await fixture.damage(damage)
        do {
            _ = try await coordinator.stageRestore(from: fixture.package)
            Issue.record("A damaged package was staged: \(damage)")
        } catch let error as RestoreError {
            #expect(
                error.localizedDescription.contains("backup")
                    || error.localizedDescription.contains("originals")
                    || error.localizedDescription.contains("manifest.json")
                    || error.localizedDescription.contains("library.sqlite"))
            #expect(!error.localizedDescription.contains(fixture.files.directory.path))
        }
        #expect(try fixture.capture() == before)
        #expect(try fixture.generationNames() == generations)
        try await coordinator.close()
    }

    @Test(arguments: [
        "../escape", "/tmp/escape", "originals/../escape", "originals/a/b.original",
        "originals/..\\escape.original", "originals/%2e%2e/escape", "library.sqlite\u{0}",
    ])
    func traversalNeverTouchesAnOutsideSentinel(path: String) async throws {
        let fixture = RestoreFixture()
        defer { fixture.files.remove() }
        let coordinator = LibraryCoordinator(root: fixture.files.root)
        _ = try await fixture.seed(coordinator)
        let sentinel = fixture.files.directory.appending(path: "escape")
        let bytes = Data("unrelated file".utf8)
        try bytes.write(to: sentinel)
        let before = try fixture.capture()
        let manifest = try fixture.manifest()
        try fixture.write(
            manifest,
            files: manifest.files + [
                SnapshotFile(path: path, byteCount: 1, sha256: String(repeating: "0", count: 64))
            ])
        await #expect(throws: RestoreError.self) {
            _ = try await coordinator.stageRestore(from: fixture.package)
        }
        #expect(try Data(contentsOf: sentinel) == bytes)
        #expect(try fixture.capture() == before)
        try await coordinator.close()
    }

    @Test(arguments: [
        "backup.json", "manifest.json", "library.sqlite", "originals", "asset", "package",
        "._backup.json",
    ])
    func symlinksAreRejectedWithoutTouchingTheirTargets(item: String) async throws {
        let fixture = RestoreFixture()
        defer { fixture.files.remove() }
        let coordinator = LibraryCoordinator(root: fixture.files.root)
        let asset = try await fixture.seed(coordinator)
        let before = try fixture.capture()
        let source: URL
        if item == "package" {
            source = fixture.package
        } else if item == "asset" {
            source = fixture.package.appending(path: "originals/\(asset.storageKey)")
        } else {
            source = fixture.package.appending(path: item)
        }
        if item.hasPrefix("._") { try Data("metadata".utf8).write(to: source) }
        let target = fixture.files.directory.appending(path: "symlink-target")
        try FileManager.default.moveItem(at: source, to: target)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
        let targetBytes = try fixture.capture(at: target)
        await #expect(throws: RestoreError.self) {
            _ = try await coordinator.stageRestore(from: fixture.package)
        }
        #expect(try fixture.capture(at: target) == targetBytes)
        #expect(try fixture.capture() == before)
        try await coordinator.close()
    }

    @Test
    func supportedOldSchemaMigratesOnlyTheIndependentCopy() async throws {
        let fixture = RestoreFixture()
        defer { fixture.files.remove() }
        let coordinator = LibraryCoordinator(root: fixture.files.root)
        let active = try await coordinator.open()
        try await fixture.legacyPackage()
        let before = try fixture.capture()
        let sourceBytes = try fixture.capture(at: fixture.package)
        let staged = try await coordinator.stageRestore(from: fixture.package)
        #expect(staged.library.manifest.libraryID != active.manifest.libraryID)
        #expect(staged.summary.counts["watch"] == 1)
        #expect(staged.summary.counts["taskPart"] == 0)
        #expect(
            staged.summary.appliedMigrations
                == Array(LibrarySchema.migrator.migrations.dropFirst(2)))
        let reader = try RestoreDatabase.open(
            in: LibraryFiles.generation(staged.library.generationID, in: fixture.files.root),
            readonly: true)
        let watches = try await reader.read(WatchQueries.fetchAll)
        #expect(watches.first?.name == "Older record – 時計")
        #expect(watches.first?.serial == "000/12-34")
        try reader.close()
        #expect(try fixture.capture(at: fixture.package) == sourceBytes)
        for (path, bytes) in before {
            #expect(try Data(contentsOf: fixture.files.root.appending(path: path)) == bytes)
        }
        #expect(try await coordinator.open() == active)
        try await coordinator.close()
    }

    @Test
    func failedForwardMigrationKeepsActiveLibraryAndSourceUnchanged() async throws {
        let fixture = RestoreFixture()
        defer { fixture.files.remove() }
        var migrator = LibrarySchema.migrator
        migrator.registerMigration("v18-fixture-failure") { db in
            try db.execute(sql: "ALTER TABLE watch ADD COLUMN fixture TEXT")
            if try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM watch WHERE name = 'Older record – 時計'") == 1
            {
                try db.execute(sql: "UPDATE watch SET name = 'Changed only in staging'")
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let coordinator = LibraryCoordinator(root: fixture.files.root, migrator: migrator)
        let active = try await coordinator.open()
        try await fixture.legacyPackage()
        let before = try fixture.capture()
        let sourceBytes = try fixture.capture(at: fixture.package)
        let generations = try fixture.generationNames()
        await #expect(throws: RestoreError.migrationFailed) {
            _ = try await coordinator.stageRestore(from: fixture.package)
        }
        #expect(try fixture.capture() == before)
        #expect(try fixture.capture(at: fixture.package) == sourceBytes)
        #expect(try fixture.generationNames() == generations)
        #expect(try await coordinator.open() == active)
        try await coordinator.close()
    }

    @Test(arguments: RestoreFailure.allCases)
    func copySpaceCancellationAndPublishFailuresKeepActiveData(failure: RestoreFailure) async throws
    {
        let fixture = RestoreFixture()
        defer { fixture.files.remove() }
        let state = Mutex(false)
        let dependencies = LibraryDependencies(
            restoreCheckpoint: { step in
                #expect(!Thread.isMainThread)
                if case .copiedChunk = step {
                    state.withLock { $0 = true }
                    if failure == .diskFull { throw CocoaError(.fileWriteOutOfSpace) }
                    if failure == .cancel { withUnsafeCurrentTask { $0?.cancel() } }
                    if failure == .growingFile {
                        let handle = try FileHandle(
                            forWritingTo: LibraryFiles.database(in: fixture.package))
                        defer { try? handle.close() }
                        try handle.seekToEnd()
                        try handle.write(contentsOf: Data("extra".utf8))
                    }
                }
                if case .beforeMigration = step, failure == .stagedOriginal {
                    let generations = fixture.files.root.appending(path: "generations")
                    let name = try #require(
                        try FileManager.default.contentsOfDirectory(atPath: generations.path).first
                        { $0.hasPrefix(".restore-") })
                    let originals = LibraryFiles.originals(in: generations.appending(path: name))
                    let original = try #require(
                        try FileManager.default.contentsOfDirectory(
                            at: originals, includingPropertiesForKeys: nil
                        ).first)
                    var bytes = try Data(contentsOf: original)
                    bytes[0] ^= 1
                    try bytes.write(to: original)
                }
                if case .beforePublish = step, failure == .publish {
                    throw CocoaError(.fileWriteUnknown)
                }
            },
            restoreAvailableCapacity: { _ in
                if failure == .noSpace { return 0 }
                if failure == .spaceDrops && state.withLock({ $0 }) { return 0 }
                return Int64.max
            })
        let coordinator = LibraryCoordinator(root: fixture.files.root, dependencies: dependencies)
        _ = try await fixture.seed(coordinator)
        let before = try fixture.capture()
        let generations = try fixture.generationNames()
        await #expect(throws: (any Error).self) {
            _ = try await coordinator.stageRestore(from: fixture.package)
        }
        #expect(try fixture.capture() == before)
        #expect(try fixture.generationNames() == generations)
        #expect(try await coordinator.read(FileAssetQueries.fetchAll).count == 1)
        try await coordinator.close()
    }

    @Test
    func closedCoordinatorAndInsideLibrarySourcesCannotStage() async throws {
        let fixture = RestoreFixture()
        defer { fixture.files.remove() }
        let coordinator = LibraryCoordinator(root: fixture.files.root)
        await #expect(throws: LibraryError.notOpen) {
            _ = try await coordinator.stageRestore(from: fixture.package)
        }
        _ = try await coordinator.open()
        let before = try fixture.capture()
        await #expect(throws: RestoreError.self) {
            _ = try await coordinator.stageRestore(
                from: fixture.files.root.appending(path: "inside.watchbackup"))
        }
        #expect(try fixture.capture() == before)
        try await coordinator.close()
    }

    @Test
    func rejectionPreservesPreviouslyValidatedGenerations() async throws {
        let fixture = RestoreFixture()
        defer { fixture.files.remove() }
        let coordinator = LibraryCoordinator(root: fixture.files.root)
        _ = try await fixture.seed(coordinator)
        _ = try await coordinator.stageRestore(from: fixture.package)
        let before = try fixture.capture()
        let generations = try fixture.generationNames()
        try await fixture.damage(.missingAsset)
        await #expect(throws: RestoreError.self) {
            _ = try await coordinator.stageRestore(from: fixture.package)
        }
        #expect(try fixture.capture() == before)
        #expect(try fixture.generationNames() == generations)
        try await coordinator.close()
    }
    @Test
    func appleDoubleMetadataIsIgnoredAndNeverCopied() async throws {
        let fixture = RestoreFixture()
        defer { fixture.files.remove() }
        let coordinator = LibraryCoordinator(root: fixture.files.root)
        let asset = try await fixture.seed(coordinator)
        let before = try fixture.capture()
        for path in [
            "backup.json", "manifest.json", "library.sqlite", "originals/\(asset.storageKey)",
        ] {
            let source = fixture.package.appending(path: path)
            let sidecar = source.deletingLastPathComponent().appending(
                path: "._\(source.lastPathComponent)")
            let bytes = Data("fixture metadata".utf8)
            let attributeResult = source.path.withCString { sourcePath in
                bytes.withUnsafeBytes { buffer in
                    setxattr(sourcePath, "com.ure.fixture", buffer.baseAddress, buffer.count, 0, 0)
                }
            }
            #expect(attributeResult == 0)
            let packResult = source.path.withCString { sourcePath in
                sidecar.path.withCString { sidecarPath in
                    copyfile(sourcePath, sidecarPath, nil, copyfile_flags_t(COPYFILE_PACK))
                }
            }
            #expect(packResult == 0)
            #expect(try Data(contentsOf: sidecar).count > 0)
        }
        let staged = try await coordinator.stageRestore(from: fixture.package)
        let directory = LibraryFiles.generation(staged.library.generationID, in: fixture.files.root)
        #expect(try fixture.capture(at: directory).keys.allSatisfy { !$0.contains("._") })
        for (path, bytes) in before {
            #expect(try Data(contentsOf: fixture.files.root.appending(path: path)) == bytes)
        }
        try await coordinator.close()
    }
}

nonisolated enum RestoreDamage: String, CaseIterable, Sendable {
    case missingAsset, wrongHash, corruptDatabase, truncatedDatabase, invalidForeignKey
    case wrongCounts, wrongIdentity, wrongAssetHash, unexpectedAsset, removedConstraint,
        extraTrigger
    case futureVersion, futureMigration, outOfOrderMigration, malformedManifest,
        malformedLibraryManifest
    case duplicatePath, negativeSize, overflowSize, oversizedManifest, crossJobPart, wrongFileKind
}

nonisolated enum RestoreFailure: Sendable, CaseIterable {
    case noSpace, spaceDrops, diskFull, cancel, growingFile, stagedOriginal, publish
}

nonisolated private struct RestoreFixture: Sendable {
    let files = ImportFixture()
    var package: URL { files.directory.appending(path: "fixture.watchbackup") }

    func seed(_ coordinator: LibraryCoordinator) async throws -> FileAsset {
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let source = try files.source(type: .png)
        let photo = try #require(
            await PhotoService(coordinator: coordinator).importFiles([source], for: owners[0]).first
        ).outcome.get()
        let asset = photo.asset
        _ = try await coordinator.exportBackup(to: package, applicationVersion: "fixture")
        return asset
    }

    func manifest() throws -> BackupManifest {
        try LibraryFiles.read(BackupManifest.self, from: package.appending(path: "backup.json"))
    }

    func write(
        _ manifest: BackupManifest, version: Int? = nil, libraryID: UUID? = nil,
        migrations: [String]? = nil, counts: [String: Int]? = nil, files: [SnapshotFile]? = nil
    ) throws {
        try LibraryFiles.write(
            BackupManifest(
                formatVersion: version ?? manifest.formatVersion, exportedAt: manifest.exportedAt,
                libraryID: libraryID ?? manifest.libraryID,
                applicationVersion: manifest.applicationVersion,
                migrations: migrations ?? manifest.migrations, counts: counts ?? manifest.counts,
                files: files ?? manifest.files), to: package.appending(path: "backup.json"))
    }

    func fingerprint(_ path: String) throws -> SnapshotFile {
        let bytes = try Data(contentsOf: package.appending(path: path))
        return SnapshotFile(
            path: path, byteCount: Int64(bytes.count),
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    func refreshDatabaseDeclaration() throws {
        let manifest = try manifest()
        let database = try fingerprint("library.sqlite")
        try write(
            manifest, files: manifest.files.map { $0.path == "library.sqlite" ? database : $0 })
    }

    func damage(_ damage: RestoreDamage) async throws {
        let manifest = try manifest()
        let original = try #require(manifest.files.first { $0.path.hasPrefix("originals/") })
        switch damage {
        case .missingAsset:
            try FileManager.default.removeItem(at: package.appending(path: original.path))
        case .wrongHash:
            var bytes = try Data(contentsOf: package.appending(path: original.path))
            bytes[0] ^= 1
            try bytes.write(to: package.appending(path: original.path))
        case .corruptDatabase, .truncatedDatabase:
            let url = LibraryFiles.database(in: package)
            if damage == .corruptDatabase {
                try Data("broken sqlite".utf8).write(to: url)
            } else {
                let bytes = try Data(contentsOf: url)
                try bytes.prefix(bytes.count / 2).write(to: url)
            }
            try refreshDatabaseDeclaration()
        case .wrongCounts:
            var counts = manifest.counts
            counts["watch", default: 0] += 1
            try write(manifest, counts: counts)
        case .wrongIdentity:
            try write(manifest, libraryID: UUID())
        case .wrongAssetHash:
            try await mutatePackage(
                "UPDATE fileAsset SET sha256 = ?", arguments: [String(repeating: "0", count: 64)])
        case .invalidForeignKey:
            try await mutatePackage("UPDATE job SET watchID = ?", arguments: [UUID().uuidString])
        case .unexpectedAsset:
            let extra = "originals/\(UUID().uuidString).original"
            try Data("extra".utf8).write(to: package.appending(path: extra))
            try write(manifest, files: manifest.files + [fingerprint(extra)])
        case .removedConstraint:
            try await mutatePackage("DROP INDEX job_one_open_per_watch")
        case .extraTrigger:
            try await mutatePackage(
                "CREATE TRIGGER sqlitex_wipe AFTER INSERT ON fileAsset BEGIN DELETE FROM note; END")
        case .futureVersion:
            try write(manifest, version: BackupManifest.currentVersion + 1)
        case .futureMigration:
            try write(manifest, migrations: manifest.migrations + ["v999-future"])
        case .outOfOrderMigration:
            try write(manifest, migrations: manifest.migrations.reversed())
        case .malformedManifest:
            try Data("{\"files\":".utf8).write(to: package.appending(path: "backup.json"))
        case .malformedLibraryManifest:
            try Data("not JSON".utf8).write(to: package.appending(path: "manifest.json"))
            try write(
                manifest,
                files: manifest.files.map { file in
                    if file.path == "manifest.json" { return try fingerprint(file.path) }
                    return file
                })
        case .duplicatePath:
            try write(manifest, files: manifest.files + [original])
        case .negativeSize:
            try write(
                manifest,
                files: manifest.files + [
                    SnapshotFile(
                        path: "originals/\(UUID().uuidString).original", byteCount: -1,
                        sha256: original.sha256)
                ])
        case .overflowSize:
            try write(
                manifest,
                files: manifest.files.map {
                    SnapshotFile(path: $0.path, byteCount: Int64.max, sha256: $0.sha256)
                })
        case .oversizedManifest:
            let handle = try FileHandle(forWritingTo: package.appending(path: "backup.json"))
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(RestoreFiles.maximumManifestBytes + 1))
        case .crossJobPart:
            try await seedCrossJobPart()
        case .wrongFileKind:
            try await mutatePackage("UPDATE libraryItem SET kind = 'Document', photoStage = NULL")
        }
    }

    func mutatePackage(_ sql: String, arguments: StatementArguments = []) async throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        let writer = try DatabaseQueue(
            path: LibraryFiles.database(in: package).path, configuration: configuration)
        try await writer.write { try $0.execute(sql: sql, arguments: arguments) }
        try writer.close()
        try refreshDatabaseDeclaration()
    }

    func seedCrossJobPart() async throws {
        let writer = try DatabaseQueue(path: LibraryFiles.database(in: package).path)
        try await writer.write { db in
            let watchID = UUID().uuidString
            let jobID = UUID().uuidString
            let taskID = UUID().uuidString
            let partID = UUID().uuidString
            let originalJobID = try #require(try String.fetchOne(db, sql: "SELECT id FROM job"))
            try db.execute(
                sql:
                    "INSERT INTO watch (id, name, createdAt, updatedAt) VALUES (?, 'Other watch', 0, 0)",
                arguments: [watchID])
            try db.execute(
                sql:
                    "INSERT INTO job (id, watchID, title, stage, intakeSnapshot, createdAt, updatedAt) VALUES (?, ?, 'Other job', 'Planned', '{}', 0, 0)",
                arguments: [jobID, watchID])
            try db.execute(
                sql:
                    "INSERT INTO jobTask (id, jobID, title, status, createdAt, updatedAt) VALUES (?, ?, 'Task', 'To do', 0, 0)",
                arguments: [taskID, originalJobID])
            try db.execute(
                sql:
                    "INSERT INTO partRequirement (id, jobID, description, quantity, compatibility, status, createdAt, updatedAt) VALUES (?, ?, 'Part', 1, 'Unchecked', 'Needed', 0, 0)",
                arguments: [partID, jobID])
            try db.execute(
                sql: "INSERT INTO taskPart (taskID, partID) VALUES (?, ?)",
                arguments: [taskID, partID])
        }
        let counts = try await writer.read(BackupQueries.counts)
        try writer.close()
        let manifest = try manifest()
        try write(manifest, counts: counts)
        try refreshDatabaseDeclaration()
    }

    func legacyPackage() async throws {
        try FileManager.default.createDirectory(
            at: LibraryFiles.originals(in: package), withIntermediateDirectories: true)
        let library = LibraryManifest(
            formatVersion: 1, libraryID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.125))
        try LibraryFiles.write(library, to: package.appending(path: "manifest.json"))
        let writer = try DatabaseQueue(path: LibraryFiles.database(in: package).path)
        try LibrarySchema.migrator.migrate(writer, upTo: "v2-watches")
        try await writer.write { db in
            try db.execute(
                sql: "INSERT INTO libraryMetadata (id, createdAt) VALUES (?, ?)",
                arguments: [library.libraryID.uuidString, library.createdAt.timeIntervalSince1970])
            try db.execute(
                sql:
                    "INSERT INTO watch (id, name, serial, createdAt, updatedAt) VALUES (?, 'Older record – 時計', '000/12-34', 0, 0)",
                arguments: [UUID().uuidString])
        }
        let counts = try await writer.read(BackupQueries.counts)
        try writer.close()
        let manifest = BackupManifest(
            formatVersion: 1, exportedAt: Date(timeIntervalSince1970: 1_700_000_001),
            libraryID: library.libraryID,
            applicationVersion: "older",
            migrations: Array(LibrarySchema.migrator.migrations.prefix(2)), counts: counts,
            files: try [fingerprint("library.sqlite"), fingerprint("manifest.json")])
        try write(manifest)
    }

    func capture(at directory: URL? = nil) throws -> [String: Data] {
        let location = directory ?? files.root
        if try location.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            return [location.lastPathComponent: try Data(contentsOf: location)]
        }
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: location, includingPropertiesForKeys: [.isRegularFileKey]))
        var values: [String: Data] = [:]
        for case let file as URL in enumerator {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                values[String(file.path.dropFirst(location.path.count + 1))] = try Data(
                    contentsOf: file)
            }
        }
        return values
    }

    func generationNames() throws -> Set<String> {
        Set(
            try FileManager.default.contentsOfDirectory(
                atPath: files.root.appending(path: "generations").path))
    }
}
