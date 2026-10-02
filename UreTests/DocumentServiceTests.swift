import CoreGraphics
import Foundation
import GRDB
import PDFKit
import Testing

@testable import Ure

nonisolated struct DocumentServiceTests {
    @Test
    func everyScopePreservesSourceContextAndReadsAllPagesAfterSourceRemovalAndRestart() async throws
    {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let source = try DocumentFixture.source(in: fixture)
        let bytes = try Data(contentsOf: source)
        let service = DocumentService(coordinator: coordinator)
        var saved: [DocumentRecord] = []
        for owner in owners {
            let document = try await service.importFiles([source], for: owner)[0].outcome.get()
            #expect(document.item.kind == .document && document.item.belongs(to: owner))
            #expect(document.asset.detectedType == .pdf)
            #expect(document.item.sourceURL.isEmpty && document.item.photoStage == nil)
            var draft = DocumentDraft(item: document.item)
            draft.title = "  Technical sheet – Å時計  "
            draft.sourceURL = "  https://example.com/technical.pdf  "
            draft.sourceDescription = "Manufacturer, revision 3"
            draft.notes = "Keep punctuation: 001 / e\u{301}\n🔧"
            let item = try await service.save(draft, for: owner, editing: document.id)
            #expect(item.title == "Technical sheet – Å時計")
            #expect(item.sourceURL == "https://example.com/technical.pdf")
            #expect(item.sourceDescription == draft.sourceDescription && item.notes == draft.notes)
            #expect(
                item.fileAssetID == document.asset.id && item.createdAt == document.item.createdAt)
            saved.append(DocumentRecord(item: item, asset: document.asset))
        }
        try FileManager.default.removeItem(at: source)
        try await coordinator.close()
        let reopened = LibraryCoordinator(root: fixture.root)
        _ = try await reopened.open()
        #expect(
            Set(try await reopened.read(DocumentQueries.fetchAll).map(\.id)) == Set(saved.map(\.id))
        )
        for record in saved {
            let document = try await DocumentService(coordinator: reopened).document(
                for: record.asset.id)
            #expect(document.pageCount == 3)
            for index in 0..<3 { #expect(document.page(at: index) != nil) }
            let export = fixture.directory.appending(path: "export-\(record.id).pdf")
            try await reopened.exportOriginal(record.asset.id, to: export)
            #expect(try Data(contentsOf: export) == bytes)
            try Data("old destination".utf8).write(to: export)
            try await reopened.exportOriginal(record.asset.id, to: export)
            #expect(try Data(contentsOf: export) == bytes)
        }
        try await reopened.close()
    }

    @Test
    func mixedBatchRejectsCorruptProtectedAndNonPDFsWithoutLosingSuccesses() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        let valid = try DocumentFixture.source(in: fixture)
        let corrupt = try fixture.file("%PDF-1.7\nbroken", named: "broken.pdf")
        let locked = try fixture.source(type: .pdf, encrypted: true)
        let restricted = try fixture.source(type: .pdf, ownerPasswordOnly: true)
        let photo = try fixture.source(type: .png)
        let service = DocumentService(coordinator: coordinator)
        let results = await service.importFiles(
            [valid, corrupt, locked, restricted, photo], for: owner)
        #expect(results.count == 5)
        let saved = try results[0].outcome.get()
        #expect(results[1].outcome.documentFailure == .corruptPDF)
        #expect(results[2].outcome.documentFailure == .protectedPDF)
        #expect(results[3].outcome.documentFailure == .protectedPDF)
        #expect(results[4].outcome.documentFailure == .notPDF)
        #expect(try await coordinator.read(DocumentQueries.fetchAll) == [saved])
        #expect(try await coordinator.read(FileAssetQueries.fetchAll) == [saved.asset])
        let limited = DocumentService(
            coordinator: coordinator, maximumByteCount: 1, maximumFileCount: 1)
        #expect(
            await limited.importFiles([valid], for: owner)[0].outcome.documentFailure
                == .fileImport(.oversized(1)))
        #expect(
            await limited.importFiles([valid, valid], for: owner).allSatisfy {
                $0.outcome.documentFailure == .fileImport(.tooManyFiles(1))
            })
        try await coordinator.close()
    }

    @Test(arguments: [FileImportCheckpoint.beforeCommit, .afterCommit])
    func originalAndItemShareOneCommit(checkpoint: FileImportCheckpoint) async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(
            root: fixture.root,
            dependencies: LibraryDependencies(importCheckpoint: { step in
                #expect(!Thread.isMainThread)
                if step == checkpoint { throw CocoaError(.fileWriteOutOfSpace) }
            }))
        let info = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        let source = try DocumentFixture.source(in: fixture)
        let result = await DocumentService(coordinator: coordinator).importFiles(
            [source], for: owner)[0]
        let expected = checkpoint == .afterCommit ? 1 : 0
        #expect(try await coordinator.read(DocumentQueries.fetchAll).count == expected)
        #expect(try await coordinator.read(FileAssetQueries.fetchAll).count == expected)
        #expect(
            try LibraryFiles.originalFiles(
                in: LibraryFiles.originals(
                    in: LibraryFiles.generation(info.generationID, in: fixture.root))
            ).count == expected)
        if expected == 1 {
            #expect(try result.outcome.get().item.kind == .document)
        } else {
            if case .failure(let error) = result.outcome {
                #expect(error is CocoaError)
            } else {
                Issue.record("A failed precommit import reported success")
            }
        }
        try await coordinator.close()
    }

    @Test
    func closedJobsRejectImportsAndStaleSavesButStayReadableAndExportable() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        guard case .job(let jobID) = owners[1] else { throw NoteFixtureError() }
        let source = try DocumentFixture.source(in: fixture)
        let service = DocumentService(coordinator: coordinator)
        let document = try await service.importFiles([source], for: owners[1])[0].outcome.get()
        var closure = JobTransitionDraft(stage: .completed)
        closure.outcome = "Finished"
        _ = try await JobService(coordinator: coordinator).transition(jobID, using: closure)
        var draft = DocumentDraft(item: document.item)
        draft.notes = "Pending correction"
        await #expect(throws: JobError.closedJob) {
            try await service.save(draft, for: owners[1], editing: document.id)
        }
        let result = await service.importFiles([source], for: owners[1])[0]
        if case .failure(let error) = result.outcome {
            #expect(error as? JobError == .closedJob)
        } else {
            Issue.record("Closed job imported a document")
        }
        #expect(try await service.document(for: document.asset.id).pageCount == 3)
        try await service.export(
            document.asset.id, to: fixture.directory.appending(path: "export.pdf"))
        #expect(try await coordinator.read(DocumentQueries.fetchAll) == [document])
        #expect(try await coordinator.read(FileAssetQueries.fetchAll) == [document.asset])
        _ = try await JobService(coordinator: coordinator).reopen(
            jobID, using: JobTransitionDraft(stage: .planned))
        #expect(
            try await service.save(draft, for: owners[1], editing: document.id).notes == draft.notes
        )
        try await coordinator.close()
    }

    @Test
    func wrongScopeAndKindCannotConvertReferencesAndInvalidURLsStayInvalid() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let source = try DocumentFixture.source(in: fixture)
        let service = DocumentService(coordinator: coordinator)
        let document = try await service.importFiles([source], for: owners[0])[0].outcome.get()
        let draft = DocumentDraft(item: document.item)
        await #expect(throws: DocumentError.ownerMismatch) {
            try await service.save(draft, for: owners[2], editing: document.id)
        }
        let referenceService = ReferenceService(coordinator: coordinator)
        await #expect(throws: ReferenceError.notLink) {
            try await referenceService.save(
                ReferenceFixture.draft, for: owners[0], editing: document.id)
        }
        let link = try await referenceService.save(
            ReferenceFixture.draft, for: owners[0], editing: nil)
        await #expect(throws: DocumentError.notPDF) {
            try await service.save(draft, for: owners[0], editing: link.id)
        }
        for url in [
            "javascript:alert(1)", "file:///local.pdf", "https://", "https://example.com/bad path",
        ] {
            var invalid = draft
            invalid.sourceURL = url
            await #expect(throws: ReferenceValidationError.self) {
                try await service.save(invalid, for: owners[0], editing: document.id)
            }
        }
        #expect(try await coordinator.read(DocumentQueries.fetchAll) == [document])
        try await coordinator.close()
    }

    @Test
    func invalidOrMissingManagedOriginalKeepsTheDocumentRecord() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        let source = try DocumentFixture.source(in: fixture)
        let service = DocumentService(coordinator: coordinator)
        let document = try await service.importFiles([source], for: owner)[0].outcome.get()
        let original = try await coordinator.originalURL(for: document.asset.id)
        let restricted = try fixture.source(type: .pdf, ownerPasswordOnly: true)
        try Data(contentsOf: restricted).write(to: original)
        await #expect(throws: DocumentError.protectedPDF) {
            try await service.document(for: document.asset.id)
        }
        try Data("broken PDF".utf8).write(to: original)
        await #expect(throws: DocumentError.corruptPDF) {
            try await service.document(for: document.asset.id)
        }
        try FileManager.default.removeItem(at: original)
        await #expect(throws: (any Error).self) {
            try await service.document(for: document.asset.id)
        }
        #expect(try await coordinator.read(DocumentQueries.fetchAll) == [document])
        try await coordinator.close()
    }

    @Test
    func attachmentWriteFailureRollsBackItemAssetAndOriginal() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        let info = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql:
                    "CREATE TRIGGER failDocument BEFORE INSERT ON libraryItem BEGIN SELECT RAISE(ABORT, 'fixture failure'); END"
            )
        }
        let source = try DocumentFixture.source(in: fixture)
        let result = await DocumentService(coordinator: coordinator).importFiles(
            [source], for: owner)[0]
        if case .success = result.outcome { Issue.record("Attachment failure must fail import") }
        #expect(try await coordinator.read(DocumentQueries.fetchAll).isEmpty)
        #expect(try await coordinator.read(FileAssetQueries.fetchAll).isEmpty)
        #expect(
            try LibraryFiles.originalFiles(
                in: LibraryFiles.originals(
                    in: LibraryFiles.generation(info.generationID, in: fixture.root))
            ).isEmpty)
        try await coordinator.close()
    }

    @Test
    func forwardMigrationPreservesPhotoRowsLinksAndWatchCoverReferences() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.directory, withIntermediateDirectories: true)
        let database = try DatabaseQueue(path: fixture.directory.appending(path: "v9.sqlite").path)
        try LibrarySchema.migrator.migrate(database, upTo: "v9-photos")
        let watchID = UUID()
        let now = Date(timeIntervalSince1970: 1_000)
        let assetID = UUID()
        let asset = FileAsset(
            id: assetID, storageKey: ManagedOriginals.storageKey(assetID),
            originalFilename: "movement.png",
            detectedType: .png, byteCount: 123, sha256: String(repeating: "a", count: 64),
            importedAt: now,
            pixelWidth: 16, pixelHeight: 12, orientation: 6)
        var photo = LibraryItem(
            id: UUID(), watchID: watchID, jobID: nil, caliberID: nil,
            kind: .photo, title: "Movement", sourceURL: "", sourceDescription: "", notes: "",
            createdAt: now, updatedAt: now)
        photo.fileAssetID = asset.id
        photo.photoStage = .before
        photo.caption = "Keep caption"
        let link = try ReferenceFixture.draft.record(
            id: UUID(), owner: .watch(watchID), createdAt: now, updatedAt: now)
        try database.write { db in
            try db.execute(
                sql: "INSERT INTO watch (id, name, createdAt, updatedAt) VALUES (?, 'Watch', ?, ?)",
                arguments: [
                    watchID.uuidString, now.timeIntervalSince1970, now.timeIntervalSince1970,
                ])
            try asset.insert(db)
            try photo.insert(db)
            try link.insert(db)
            try db.execute(
                sql: "UPDATE watch SET coverPhotoID = ? WHERE id = ?",
                arguments: [photo.id.uuidString, watchID.uuidString])
        }
        let watches = try database.read(WatchQueries.fetchAll)
        let items = try database.read(LibraryItemQueries.fetchAll)
        try LibrarySchema.migrator.migrate(database)
        #expect(try database.read(WatchQueries.fetchAll) == watches)
        #expect(try database.read(LibraryItemQueries.fetchAll) == items)
        #expect(try database.read(FileAssetQueries.fetchAll) == [asset])
        #expect(try database.read { try Bool.fetchOne($0, sql: "PRAGMA foreign_keys") } == true)
        try database.read { try $0.checkForeignKeys() }
        #expect(throws: DatabaseError.self) {
            try database.write { db in
                try db.execute(
                    sql: "UPDATE watch SET coverPhotoID = ? WHERE id = ?",
                    arguments: [link.id.uuidString, watchID.uuidString])
            }
        }
        try database.write { db in _ = try LibraryItem.deleteOne(db, key: photo.id.uuidString) }
        #expect(try database.read { try WatchQueries.fetch(watchID, in: $0)?.coverPhotoID } == nil)
        try database.close()
    }
}

nonisolated private extension Result where Success == DocumentRecord, Failure == any Error {
    var documentFailure: DocumentError? {
        if case .failure(let error) = self { return error as? DocumentError }
        return nil
    }
}

nonisolated enum DocumentFixture {
    static func source(in fixture: ImportFixture) throws -> URL {
        try FileManager.default.createDirectory(
            at: fixture.sources, withIntermediateDirectories: true)
        let url = fixture.sources.appending(path: "Å時計-\(UUID()).wrong")
        var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = try #require(CGContext(url as CFURL, mediaBox: &bounds, nil))
        for index in 0..<3 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: Double(index) / 3, alpha: 1))
            context.fill(CGRect(x: 20, y: 20, width: 200, height: 100))
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
}
