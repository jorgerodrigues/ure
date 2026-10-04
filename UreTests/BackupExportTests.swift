import CryptoKit
import Foundation
import GRDB
import Synchronization
import Testing

@testable import Ure

nonisolated struct BackupExportTests {
    @Test
    func packageIndependentlyPreservesRecordsOriginalsHashesAndCounts() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 1_700_000_000.125)
        let coordinator = LibraryCoordinator(
            root: fixture.root, dependencies: LibraryDependencies(now: { date }))
        let info = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        for owner in owners {
            let photo = try fixture.source(type: .heic, name: "\(UUID())–時計.heic")
            let pdf = try fixture.source(type: .pdf)
            _ = try #require(
                await PhotoService(coordinator: coordinator).importFiles([photo], for: owner).first
            )
            .outcome.get()
            _ = try #require(
                await DocumentService(coordinator: coordinator).importFiles([pdf], for: owner).first
            )
            .outcome.get()
            _ = try await ReferenceService(coordinator: coordinator).save(
                ReferenceFixture.draft, for: owner, editing: nil)
        }
        let generation = LibraryFiles.generation(info.generationID, in: fixture.root)
        try Data("untracked original".utf8).write(
            to: generation.appending(path: "originals/legacy.bin"))
        try FileManager.default.createDirectory(
            at: generation.appending(path: "cache"), withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: generation.appending(path: "cache/thumbnail"))
        let summary = try await coordinator.backupSummary()
        #expect(summary.originalCount == 6)
        #expect(summary.counts["libraryItem"] == 9)
        let destination = fixture.directory.appending(path: "library.watchbackup")
        let snapshot = try await coordinator.exportBackup(
            to: destination, applicationVersion: "0.1.0")
        #expect(snapshot.createdAt == date)
        let manifest = try LibraryFiles.read(
            BackupManifest.self, from: destination.appending(path: "backup.json"))
        #expect(manifest.formatVersion == 1)
        #expect(manifest.exportedAt == date)
        #expect(manifest.libraryID == info.manifest.libraryID)
        #expect(manifest.applicationVersion == "0.1.0")
        #expect(manifest.counts == summary.counts)
        var configuration = Configuration()
        configuration.readonly = true
        let exported = try DatabaseQueue(
            path: LibraryFiles.database(in: destination).path, configuration: configuration)
        defer { try? exported.close() }
        let assets = try await exported.read(FileAssetQueries.fetchAll)
        let items = try await exported.read(LibraryItemQueries.fetchAll)
        #expect(items == (try await coordinator.read(LibraryItemQueries.fetchAll)))
        #expect(assets == (try await coordinator.read(FileAssetQueries.fetchAll)))
        let counts = try await exported.read { db -> [String: Int] in
            var counts: [String: Int] = [:]
            for table in manifest.counts.keys {
                let quoted = table.replacingOccurrences(of: "\"", with: "\"\"")
                counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(quoted)\"")
            }
            try db.checkForeignKeys()
            #expect(try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok")
            return counts
        }
        #expect(counts == manifest.counts)
        for file in manifest.files {
            let bytes = try Data(contentsOf: destination.appending(path: file.path))
            #expect(Int64(bytes.count) == file.byteCount)
            #expect(
                SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == file.sha256)
        }
        for asset in assets {
            let bytes = try Data(
                contentsOf: destination.appending(path: "originals/\(asset.storageKey)"))
            #expect(Int64(bytes.count) == asset.byteCount)
            #expect(
                SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == asset.sha256
            )
        }
        #expect(
            Set(try FileManager.default.contentsOfDirectory(atPath: destination.path)) == [
                "backup.json", "manifest.json", "library.sqlite", "originals",
            ])
        #expect(
            try LibraryFiles.originalFiles(in: LibraryFiles.originals(in: destination)).count == 6)
        #expect(
            try Data(contentsOf: generation.appending(path: "originals/legacy.bin"))
                == Data("untracked original".utf8))
        try await coordinator.close()
    }

    @Test
    func readsStayAvailableWhileMutationsAndImportsWait() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let latch = BackupLatch()
        defer { latch.resume.signal() }
        let coordinator = LibraryCoordinator(
            root: fixture.root,
            dependencies: LibraryDependencies(backupCheckpoint: latch.checkpoint))
        _ = try await coordinator.open()
        let source = try fixture.source(type: .png)
        let destination = fixture.directory.appending(path: "queued.watchbackup")
        let export = Task {
            try await coordinator.exportBackup(to: destination, applicationVersion: "fixture")
        }
        try await latch.waitUntilReached()
        let changed = Mutex(false)
        let mutation = Task {
            var draft = WatchDraft()
            draft.name = "Queued during export"
            let watch = try await WatchService(coordinator: coordinator).save(draft, editing: nil)
            changed.withLock { $0 = true }
            return watch
        }
        let imported = Task {
            try await coordinator.importOriginal(from: source, maximumByteCount: 1_000_000)
        }
        #expect(try await coordinator.read(FileAssetQueries.fetchAll).isEmpty)
        #expect(!changed.withLock { $0 })
        latch.resume.signal()
        _ = try await export.value
        let watch = try await mutation.value
        _ = try await imported.value
        #expect(changed.withLock { $0 })
        #expect(try await coordinator.read(FileAssetQueries.fetchAll).count == 1)
        #expect(try await coordinator.read(WatchQueries.fetchAll) == [watch])
        let reader = try DatabaseQueue(path: LibraryFiles.database(in: destination).path)
        #expect(try await reader.read(FileAssetQueries.fetchAll).isEmpty)
        #expect(try await reader.read(WatchQueries.fetchAll).isEmpty)
        try reader.close()
        try await coordinator.close()
    }

    @Test(arguments: [false, true])
    func cancellationOrDiskFullPreservesExistingDestinationAndReleasesWrites(cancel: Bool)
        async throws
    {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let latch = BackupLatch()
        defer { latch.resume.signal() }
        let dependencies = LibraryDependencies(backupCheckpoint: { step in
            latch.checkpoint(step)
            if case .beforePublish = step, !cancel { throw CocoaError(.fileWriteOutOfSpace) }
        })
        let coordinator = LibraryCoordinator(root: fixture.root, dependencies: dependencies)
        _ = try await coordinator.open()
        let destination = fixture.directory.appending(path: "existing.watchbackup")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("previous backup".utf8).write(to: destination.appending(path: "keep"))
        let export = Task {
            try await coordinator.exportBackup(to: destination, applicationVersion: "fixture")
        }
        try await latch.waitUntilReached()
        let mutation = Task { try await coordinator.mutate { _, _, _ in 42 } }
        if cancel { export.cancel() }
        latch.resume.signal()
        await #expect(throws: (any Error).self) { _ = try await export.value }
        #expect(try await mutation.value == 42)
        #expect(
            try Data(contentsOf: destination.appending(path: "keep"))
                == Data("previous backup".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["keep"])
        let staged = try #require(latch.staging.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
        try await coordinator.close()
    }

    @Test(arguments: [false, true])
    func missingOrChangedOriginalNeverPublishes(damaged: Bool) async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let source = try fixture.source(type: .png)
        let asset = try await coordinator.importOriginal(from: source, maximumByteCount: 1_000_000)
        let original = try await coordinator.originalURL(for: asset.id)
        if damaged {
            var bytes = try Data(contentsOf: original)
            bytes[0] ^= 1
            try bytes.write(to: original)
        } else {
            try FileManager.default.removeItem(at: original)
        }
        let destination = fixture.directory.appending(path: "failed.watchbackup")
        await #expect(throws: (any Error).self) {
            _ = try await coordinator.exportBackup(to: destination, applicationVersion: "fixture")
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try await coordinator.read(FileAssetQueries.fetchAll) == [asset])
        try await coordinator.close()
    }

    @Test(arguments: [false, true])
    func partialCopyFailurePreservesThePreviousPackage(cancel: Bool) async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let source = try fixture.source(type: .png)
        let asset = try await coordinator.importOriginal(from: source, maximumByteCount: 1_000_000)
        let destination = fixture.directory.appending(path: "partial.watchbackup")
        _ = try await coordinator.exportBackup(to: destination, applicationVersion: "previous")
        let previous = try Data(contentsOf: destination.appending(path: "backup.json"))
        try await coordinator.close()
        let failing = LibraryCoordinator(
            root: fixture.root,
            dependencies: LibraryDependencies(backupCheckpoint: { step in
                if case .copiedChunk = step {
                    if cancel {
                        withUnsafeCurrentTask { $0?.cancel() }
                    } else {
                        throw CocoaError(.fileWriteOutOfSpace)
                    }
                }
            }))
        _ = try await failing.open()
        await #expect(throws: (any Error).self) {
            _ = try await failing.exportBackup(to: destination, applicationVersion: "failed")
        }
        #expect(try Data(contentsOf: destination.appending(path: "backup.json")) == previous)
        #expect(
            try Data(contentsOf: destination.appending(path: "originals/\(asset.storageKey)"))
                == Data(contentsOf: source))
        #expect(try await failing.read(FileAssetQueries.fetchAll) == [asset])
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
                .allSatisfy { !$0.hasPrefix(".incomplete-") })
        try await failing.close()
    }

    @Test
    func alteredStagedDatabaseIsRejectedAndSuccessfulReplacementIsComplete() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let destination = fixture.directory.appending(path: "replace.watchbackup")
        _ = try await coordinator.exportBackup(to: destination, applicationVersion: "first")
        let originalManifest = try Data(contentsOf: destination.appending(path: "backup.json"))
        try await coordinator.close()
        let corrupt = LibraryCoordinator(
            root: fixture.root,
            dependencies: LibraryDependencies(backupCheckpoint: { step in
                if case .beforeValidation(let staging) = step {
                    try Data("broken sqlite".utf8).write(to: LibraryFiles.database(in: staging))
                }
            }))
        _ = try await corrupt.open()
        await #expect(throws: (any Error).self) {
            _ = try await corrupt.exportBackup(to: destination, applicationVersion: "corrupt")
        }
        #expect(
            try Data(contentsOf: destination.appending(path: "backup.json")) == originalManifest)
        try await corrupt.close()
        _ = try await coordinator.open()
        _ = try await coordinator.exportBackup(to: destination, applicationVersion: "replacement")
        #expect(
            try LibraryFiles.read(
                BackupManifest.self, from: destination.appending(path: "backup.json")
            ).applicationVersion == "replacement")
        try await coordinator.close()
    }

    @Test
    func snapshotIncludesCommittedWalWithoutCopyingWalFiles() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        let info = try await coordinator.open()
        try await coordinator.close()
        let generation = LibraryFiles.generation(info.generationID, in: fixture.root)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
        }
        let writer = try DatabaseQueue(
            path: LibraryFiles.database(in: generation).path, configuration: configuration)
        defer { try? writer.close() }
        _ = try await coordinator.open()
        var draft = WatchDraft()
        draft.name = "Committed in WAL – 時計"
        let watch = try await WatchService(coordinator: coordinator).save(draft, editing: nil)
        let wal = generation.appending(path: "library.sqlite-wal")
        #expect(try Data(contentsOf: wal).count > 0)
        let destination = fixture.directory.appending(path: "wal.watchbackup")
        _ = try await coordinator.exportBackup(to: destination, applicationVersion: "fixture")
        let exportedFiles = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(
            Set(exportedFiles) == ["library.sqlite", "manifest.json", "backup.json", "originals"])
        var readConfiguration = Configuration()
        readConfiguration.readonly = true
        let reader = try DatabaseQueue(
            path: LibraryFiles.database(in: destination).path, configuration: readConfiguration)
        #expect(try await reader.read(WatchQueries.fetchAll) == [watch])
        #expect(
            try await reader.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
                == "delete")
        try reader.close()
        try await coordinator.close()
    }

    @Test
    func destinationCannotContainOrBeWithinTheLibrary() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        await #expect(throws: LibraryError.self) {
            _ = try await coordinator.exportBackup(
                to: fixture.root.appending(path: "inside.watchbackup"),
                applicationVersion: "fixture")
        }
        await #expect(throws: LibraryError.self) {
            _ = try await coordinator.exportBackup(
                to: fixture.directory.appending(path: "wrong.zip"), applicationVersion: "fixture")
        }
        try await coordinator.close()
    }
}

nonisolated private final class BackupLatch: Sendable {
    let reached = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let staging = Mutex<URL?>(nil)

    func checkpoint(_ step: BackupCheckpoint) {
        #expect(!Thread.isMainThread)
        if case .beforeValidation(let directory) = step {
            staging.withLock { $0 = directory }
            reached.signal()
            #expect(resume.wait(timeout: .now() + 10) == .success)
        }
    }

    @concurrent func waitUntilReached() async throws {
        guard waitForSignal() else {
            throw CocoaError(.fileReadUnknown)
        }
    }

    private func waitForSignal() -> Bool { reached.wait(timeout: .now() + 10) == .success }
}
