import CoreGraphics
import CryptoKit
import Foundation
import GRDB
import ImageIO
import Testing

@testable import Ure

nonisolated struct FileImportServiceTests {
    @Test(arguments: FileAssetType.allCases)
    func realFormatsPreserveBytesMetadataAndSurviveSourceRemoval(type: FileAssetType) async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let source = try fixture.source(type: type, name: "..\\hostile–時計.wrong")
        let bytes = try Data(contentsOf: source)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = LibraryCoordinator(
            root: fixture.root, dependencies: LibraryDependencies(now: { date }))
        _ = try await coordinator.open()
        let results = await fixture.service(coordinator).importFiles([source, source])
        #expect(results.count == 2)
        var assets: [FileAsset] = []
        for result in results {
            let asset = try result.outcome.get()
            #expect(asset.detectedType == type)
            #expect(asset.originalFilename == source.lastPathComponent)
            #expect(asset.importedAt == date)
            #expect(asset.byteCount == Int64(bytes.count))
            #expect(
                asset.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            )
            #expect(asset.storageKey == ManagedOriginals.storageKey(asset.id))
            if type != .pdf {
                #expect(asset.pixelWidth == 16)
                #expect(asset.pixelHeight == 12)
                #expect(asset.orientation == 6)
            }
            assets.append(asset)
        }
        #expect(assets[0].id != assets[1].id)
        try FileManager.default.removeItem(at: source)
        try await coordinator.close()
        let reopened = LibraryCoordinator(root: fixture.root)
        _ = try await reopened.open()
        #expect(
            Set(try await reopened.read(FileAssetQueries.fetchAll).map(\.id))
                == Set(assets.map(\.id)))
        for asset in assets {
            #expect(try Data(contentsOf: try await reopened.originalURL(for: asset.id)) == bytes)
        }
        try await reopened.close()
    }

    @Test
    func batchReportsEachFailureAndStillImportsValidFiles() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let valid = try fixture.source(type: .png)
        let unsupported = try fixture.file("not a picture", named: "looks-valid.jpg")
        let corrupt = try fixture.file("%PDF-1.7\nbroken", named: "broken.pdf")
        let oversized = try fixture.file(String(repeating: "x", count: 20_000), named: "large.png")
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let service = FileImportService(
            coordinator: coordinator, maximumByteCount: 10_000, maximumFileCount: 4)
        let results = await service.importFiles([unsupported, valid, corrupt, oversized])
        #expect(results[0].outcome.failure == .unsupportedType)
        #expect(try results[1].outcome.get().detectedType == .png)
        #expect(results[2].outcome.failure == .corruptContent)
        #expect(results[3].outcome.failure == .oversized(10_000))
        #expect(try await coordinator.read(FileAssetQueries.fetchAll).count == 1)
        let tooMany = await service.importFiles(Array(repeating: valid, count: 5))
        #expect(tooMany.allSatisfy { $0.outcome.failure == .tooManyFiles(4) })
        #expect(try await coordinator.read(FileAssetQueries.fetchAll).count == 1)
        try await coordinator.close()
    }

    @Test(arguments: [
        FileImportCheckpoint.beforeRename, .afterRename, .beforeCommit, .afterCommit, .copiedChunk,
    ])
    func failuresAtEachBoundaryRecoverWithoutBrokenAssets(checkpoint: FileImportCheckpoint)
        async throws
    {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let source = try fixture.source(type: .jpeg)
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let existing = try #require(await fixture.service(coordinator).importFiles([source]).first)
            .outcome.get()
        try await coordinator.close()
        let dependencies = LibraryDependencies(importCheckpoint: { step in
            if step == checkpoint || step == .beforeCleanup {
                throw CocoaError(.fileWriteOutOfSpace)
            }
        })
        let failed = LibraryCoordinator(root: fixture.root, dependencies: dependencies)
        let info = try await failed.open()
        let outcome = try #require(await fixture.service(failed).importFiles([source]).first)
            .outcome
        if checkpoint == .afterCommit {
            #expect(try outcome.get().detectedType == .jpeg)
        } else {
            #expect(outcome.failure != nil)
        }
        try await failed.close()
        let reopened = LibraryCoordinator(root: fixture.root)
        _ = try await reopened.open()
        let assets = try await reopened.read(FileAssetQueries.fetchAll)
        #expect(assets.count == (checkpoint == .afterCommit ? 2 : 1))
        #expect(assets.contains(existing))
        let generation = LibraryFiles.generation(info.generationID, in: fixture.root)
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: generation.appending(path: "imports").path
            ).isEmpty)
        #expect(
            try LibraryFiles.originalFiles(in: LibraryFiles.originals(in: generation)).count
                == assets.count)
        for asset in assets {
            #expect(
                try Data(contentsOf: try await reopened.originalURL(for: asset.id))
                    == Data(contentsOf: source))
        }
        try await reopened.close()
    }

    @Test(arguments: [FileImportCheckpoint.copiedChunk, .afterRename, .afterCommit])
    func cancellationKeepsCommittedOriginals(checkpoint: FileImportCheckpoint) async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let source = try fixture.source(type: .png)
        let coordinator = LibraryCoordinator(
            root: fixture.root,
            dependencies: LibraryDependencies(importCheckpoint: { step in
                if step == checkpoint { withUnsafeCurrentTask { $0?.cancel() } }
            }))
        _ = try await coordinator.open()
        let task = Task { await fixture.service(coordinator).importFiles([source, source]) }
        let results = await task.value
        #expect(results[1].outcome.failure == .cancelled)
        if checkpoint == .afterCommit {
            #expect(try results[0].outcome.get().detectedType == .png)
        } else {
            #expect(results[0].outcome.failure == .cancelled)
        }
        #expect(
            try await coordinator.read(FileAssetQueries.fetchAll).count
                == (checkpoint == .afterCommit ? 1 : 0))
        try await coordinator.close()
    }

    @Test
    func cleanupAndSnapshotsWaitForActiveImportsAndMatchCommittedRows() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let source = try fixture.source(type: .heic)
        let coordinator = LibraryCoordinator(
            root: fixture.root,
            dependencies: LibraryDependencies(importCheckpoint: { _ in
                #expect(!Thread.isMainThread)
            }))
        _ = try await coordinator.open()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try await coordinator.importOriginal(
                        from: source, maximumByteCount: 1_000_000)
                }
                group.addTask { try await coordinator.recoverImports() }
                group.addTask {
                    let snapshot = try await coordinator.createSnapshot()
                    let database = try DatabaseQueue(
                        path: LibraryFiles.database(in: snapshot.directory).path)
                    let assets = try await database.read(FileAssetQueries.fetchAll)
                    #expect(
                        snapshot.files.filter { $0.path.hasPrefix("originals/") }.count
                            == assets.count)
                    for asset in assets {
                        #expect(
                            try Data(
                                contentsOf: snapshot.directory.appending(
                                    path: "originals/\(asset.storageKey)"))
                                == Data(contentsOf: source))
                    }
                    try database.close()
                }
            }
            try await group.waitForAll()
        }
        #expect(try await coordinator.read(FileAssetQueries.fetchAll).count == 8)
        try await coordinator.close()
    }

    @Test
    func pathsAndSymlinksCannotEscapeManagedStorage() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        for key in [
            "../outside", "/tmp/file", "folder/\(UUID().uuidString).original", "..\\file.original",
        ] {
            #expect(ManagedOriginals.assetID(for: key) == nil)
        }
        let source = try fixture.source(type: .png)
        let link = fixture.sources.appending(path: "link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let coordinator = LibraryCoordinator(root: fixture.root)
        let info = try await coordinator.open()
        let results = await fixture.service(coordinator).importFiles([link, fixture.sources])
        #expect(results.allSatisfy { $0.outcome.failure == .invalidSource })
        let generation = LibraryFiles.generation(info.generationID, in: fixture.root)
        let store = ManagedOriginals(generation: generation)
        try FileManager.default.removeItem(at: store.staging)
        try FileManager.default.createSymbolicLink(
            at: store.staging, withDestinationURL: fixture.sources)
        let failed = await fixture.service(coordinator).importFiles([source])
        #expect(failed[0].outcome.failure != nil)
        #expect(try await coordinator.read(FileAssetQueries.fetchAll).isEmpty)
        #expect(try Data(contentsOf: source).count > 0)
        try await coordinator.close()
    }

    @Test
    func startupRecoveryKeepsReferencedOriginalsAndUnknownFiles() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let source = try fixture.source(type: .png)
        let coordinator = LibraryCoordinator(root: fixture.root)
        let info = try await coordinator.open()
        let asset = try await coordinator.importOriginal(from: source, maximumByteCount: 1_000_000)
        let store = ManagedOriginals(
            generation: LibraryFiles.generation(info.generationID, in: fixture.root))
        let abandoned = UUID()
        let unknown = store.originals.appending(path: "earlier-evidence.bin")
        try Data("keep".utf8).write(to: unknown)
        try Data("abandoned".utf8).write(to: store.stagedURL(for: abandoned))
        try Data("abandoned".utf8).write(
            to: store.originalURL(for: ManagedOriginals.storageKey(abandoned)))
        // A staged copy with a committed key must also survive recovery.
        try Data("keep referenced".utf8).write(to: store.stagedURL(for: asset.id))
        try await coordinator.close()
        let reopened = LibraryCoordinator(root: fixture.root)
        _ = try await reopened.open()
        #expect(try await reopened.read(FileAssetQueries.fetchAll) == [asset])
        #expect(
            try Data(contentsOf: try await reopened.originalURL(for: asset.id))
                == Data(contentsOf: source))
        #expect(try Data(contentsOf: unknown) == Data("keep".utf8))
        #expect(FileManager.default.fileExists(atPath: store.stagedURL(for: asset.id).path))
        #expect(!FileManager.default.fileExists(atPath: store.stagedURL(for: abandoned).path))
        #expect(
            !FileManager.default.fileExists(
                atPath: try store.originalURL(for: ManagedOriginals.storageKey(abandoned)).path))
        try await reopened.close()
    }

    @Test(arguments: [FileAssetType.jpeg, .png, .heic])
    func truncatedImagesReturnPerFileErrors(type: FileAssetType) async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let source = try fixture.source(type: type)
        let bytes = try Data(contentsOf: source)
        try bytes.prefix(bytes.count / 2).write(to: source)
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        #expect(
            await fixture.service(coordinator).importFiles([source])[0].outcome.failure
                == .corruptContent)
        #expect(try await coordinator.read(FileAssetQueries.fetchAll).isEmpty)
        try await coordinator.close()
    }

    @Test
    func encryptedPDFIsRejected() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let source = try fixture.source(type: .pdf, encrypted: true)
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        #expect(
            await fixture.service(coordinator).importFiles([source])[0].outcome.failure
                == .encryptedPDF)
        #expect(try await coordinator.read(FileAssetQueries.fetchAll).isEmpty)
        try await coordinator.close()
    }

    @Test
    func ownerRestrictedPDFCanImportWithoutAPassword() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let source = try fixture.source(type: .pdf, ownerPasswordOnly: true)
        let document = try #require(CGPDFDocument(source as CFURL))
        #expect(document.isEncrypted)
        #expect("".withCString { document.unlockWithPassword($0) })
        #expect(document.isUnlocked)
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let asset = try await coordinator.importOriginal(from: source, maximumByteCount: 1_000_000)
        #expect(asset.detectedType == .pdf)
        #expect(
            try Data(contentsOf: try await coordinator.originalURL(for: asset.id))
                == Data(contentsOf: source))
        try await coordinator.close()
    }

    @Test
    func returnedImportDateMatchesThePersistedDateAtSubsecondPrecision() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let source = try fixture.source(type: .png)
        let date = Date(timeIntervalSinceReferenceDate: Double(812_636_121).nextUp)
        let coordinator = LibraryCoordinator(
            root: fixture.root, dependencies: LibraryDependencies(now: { date }))
        _ = try await coordinator.open()
        let asset = try await coordinator.importOriginal(from: source, maximumByteCount: 1_000_000)
        #expect(asset.importedAt == Date(timeIntervalSince1970: date.timeIntervalSince1970))
        #expect(try await coordinator.read(FileAssetQueries.fetchAll) == [asset])
        try await coordinator.close()
    }

    @Test
    func forwardMigrationPreservesLinksAndOriginals() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        let before = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let link = try await ReferenceService(coordinator: coordinator).save(
            ReferenceFixture.draft, for: owners[0], editing: nil)
        let source = try fixture.source(type: .png)
        let bytes = try Data(contentsOf: source)
        try await coordinator.mutate { db, originals, _ in
            try FileAssetMigrationFixture.removeAssets(in: db)
            try bytes.write(to: originals.appending(path: "earlier.png"))
        }
        try await coordinator.close()
        let upgraded = LibraryCoordinator(root: fixture.root)
        let after = try await upgraded.open()
        #expect(after.generationID != before.generationID)
        #expect(after.manifest == before.manifest)
        #expect(try await upgraded.read(LibraryItemQueries.fetchAll) == [link])
        #expect(try await upgraded.read(FileAssetQueries.fetchAll).isEmpty)
        #expect(
            try Data(
                contentsOf: LibraryFiles.generation(after.generationID, in: fixture.root).appending(
                    path: "originals/earlier.png")) == bytes)
        try await upgraded.close()
    }

    @Test
    func preMigrationRecoveryReadsStableKeysWithoutDecodingAssetMetadata() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let source = try fixture.source(type: .png)
        let coordinator = LibraryCoordinator(root: fixture.root)
        let before = try await coordinator.open()
        let asset = try await coordinator.importOriginal(from: source, maximumByteCount: 1_000_000)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: "ALTER TABLE fileAsset RENAME COLUMN importedAt TO legacyImportTime")
        }
        try await coordinator.close()
        var migrator = LibrarySchema.migrator
        migrator.registerMigration("v9-fixture-asset-metadata") { db in
            try db.execute(
                sql: "ALTER TABLE fileAsset RENAME COLUMN legacyImportTime TO importedAt")
        }
        let upgraded = LibraryCoordinator(root: fixture.root, migrator: migrator)
        let after = try await upgraded.open()
        #expect(after.generationID != before.generationID)
        #expect(after.manifest == before.manifest)
        #expect(try await upgraded.read(FileAssetQueries.fetchAll) == [asset])
        #expect(
            try Data(contentsOf: try await upgraded.originalURL(for: asset.id))
                == Data(contentsOf: source))
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.root.appending(path: "recovery").path
            ).count == 1)
        try await upgraded.close()
    }

    @Test
    func actualDatabaseFailureRollsBackMetadataAndRemovesOriginal() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let source = try fixture.source(type: .png)
        let coordinator = LibraryCoordinator(root: fixture.root)
        let info = try await coordinator.open()
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql:
                    "CREATE TRIGGER rejectAsset BEFORE INSERT ON fileAsset BEGIN SELECT RAISE(ABORT, 'injected failure'); END"
            )
        }
        #expect(await fixture.service(coordinator).importFiles([source])[0].outcome.failure != nil)
        #expect(try await coordinator.read(FileAssetQueries.fetchAll).isEmpty)
        #expect(
            try LibraryFiles.originalFiles(
                in: LibraryFiles.originals(
                    in: LibraryFiles.generation(info.generationID, in: fixture.root))
            ).isEmpty)
        try await coordinator.close()
    }
}

nonisolated private extension Result where Success == FileAsset, Failure == FileImportError {
    var failure: FileImportError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

nonisolated enum FileAssetMigrationFixture {
    static func removeAssets(in db: Database) throws {
        try db.execute(sql: "DROP TABLE fileAsset")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v8-file-assets'")
    }
}

nonisolated private struct ImportFixture: Sendable {
    let directory = URL.temporaryDirectory.appending(path: "UreTests/\(UUID().uuidString)")
    var root: URL { directory.appending(path: "library") }
    var sources: URL { directory.appending(path: "sources") }

    func service(_ coordinator: LibraryCoordinator) -> FileImportService {
        FileImportService(
            coordinator: coordinator, maximumByteCount: 1_000_000, maximumFileCount: 200)
    }

    func file(_ text: String, named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let url = sources.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func source(
        type: FileAssetType, name: String = UUID().uuidString, encrypted: Bool = false,
        ownerPasswordOnly: Bool = false
    )
        throws -> URL
    {
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let url = sources.appending(path: name)
        if type == .pdf {
            var bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
            var options: CFDictionary?
            if encrypted {
                options =
                    [
                        kCGPDFContextUserPassword: "fixture-password",
                        kCGPDFContextOwnerPassword: "fixture-owner",
                    ] as CFDictionary
            } else if ownerPasswordOnly {
                options =
                    [
                        kCGPDFContextOwnerPassword: "fixture-owner",
                        kCGPDFContextAllowsCopying: false,
                    ] as CFDictionary
            }
            let context = try #require(CGContext(url as CFURL, mediaBox: &bounds, options))
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(x: 10, y: 10, width: 40, height: 40))
            context.endPDFPage()
            context.closePDF()
        } else {
            let context = try #require(
                CGContext(
                    data: nil, width: 16, height: 12, bitsPerComponent: 8, bytesPerRow: 64,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
            let image = try #require(context.makeImage())
            let destination = try #require(
                CGImageDestinationCreateWithURL(url as CFURL, type.rawValue as CFString, 1, nil))
            CGImageDestinationAddImage(
                destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
            #expect(CGImageDestinationFinalize(destination))
        }
        return url
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
