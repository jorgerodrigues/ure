import CoreGraphics
import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct PhotoServiceTests {
    @Test
    func everyScopePreservesPhotoDetailsAndOriginalsAfterSourceRemovalAndRestart() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let source = try fixture.source(type: .heic, name: "Å時計.wrong")
        let bytes = try Data(contentsOf: source)
        let service = PhotoService(coordinator: coordinator)
        var saved: [PhotoRecord] = []
        for owner in owners {
            let photo = try #require(await service.importFiles([source], for: owner).first).outcome
                .get()
            #expect(photo.item.belongs(to: owner))
            #expect(photo.item.photoStage == .unclassified)
            #expect(photo.item.fileAssetID == photo.asset.id)
            #expect(photo.item.title == source.lastPathComponent)
            var draft = PhotoDraft(item: photo.item)
            draft.title = "  Movement – Å時計  "
            draft.caption = "  Before service\n🔧 e\u{301}  "
            draft.stage = .before
            let item = try await service.save(draft, for: owner, editing: photo.id)
            #expect(item.title == "Movement – Å時計")
            #expect(item.caption == draft.caption)
            #expect(item.createdAt == photo.item.createdAt)
            #expect(item.fileAssetID == photo.asset.id)
            saved.append(PhotoRecord(item: item, asset: photo.asset))
        }
        try FileManager.default.removeItem(at: source)
        try await coordinator.close()
        let reopened = LibraryCoordinator(root: fixture.root)
        _ = try await reopened.open()
        #expect(
            Set(try await reopened.read(PhotoQueries.fetchAll).map(\.id)) == Set(saved.map(\.id)))
        for photo in saved {
            let thumbnail = try await PhotoService(coordinator: reopened).image(
                for: photo.asset.id, thumbnail: true)
            let image = try await PhotoService(coordinator: reopened).image(
                for: photo.asset.id, thumbnail: false)
            #expect(image.width == 12 && image.height == 16)
            #expect(thumbnail.width == 12 && thumbnail.height == 16)
            let export = fixture.directory.appending(path: "export-\(photo.id).heic")
            try await reopened.exportOriginal(photo.asset.id, to: export)
            #expect(try Data(contentsOf: export) == bytes)
            try Data("previous export".utf8).write(to: export)
            try await reopened.exportOriginal(photo.asset.id, to: export)
            #expect(try Data(contentsOf: export) == bytes)
            await #expect(throws: LibraryError.self) {
                try await reopened.exportOriginal(
                    photo.asset.id, to: fixture.root.appending(path: "export.heic"))
            }
        }
        try await reopened.close()
    }

    @Test
    func mixedBatchKeepsSuccessesRejectsPDFsAndAppliesCountAndSizeLimits() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        let valid = try fixture.source(type: .png)
        let pdf = try fixture.source(type: .pdf)
        let corrupt = try fixture.file("\u{89}PNG broken", named: "broken.png")
        let unsupported = try fixture.file("text", named: "text.jpg")
        let large = try fixture.file(String(repeating: "x", count: 20_000), named: "large.jpg")
        let service = PhotoService(
            coordinator: coordinator, maximumByteCount: 10_000, maximumFileCount: 5)
        let results = await service.importFiles(
            [valid, pdf, corrupt, unsupported, large], for: owner)
        #expect(results.count == 5)
        #expect(try results[0].outcome.get().asset.detectedType == .png)
        #expect(results[1].outcome.failure == .notPhoto)
        #expect(results[2].outcome.failure != nil)
        #expect(results[3].outcome.failure == .notPhoto)
        #expect(results[4].outcome.failure == .fileImport(.oversized(10_000)))
        #expect(try await coordinator.read(PhotoQueries.fetchAll).count == 1)
        #expect(try await coordinator.read(FileAssetQueries.fetchAll).count == 1)
        let rejected = await service.importFiles(Array(repeating: valid, count: 6), for: owner)
        #expect(rejected.allSatisfy { $0.outcome.failure == .fileImport(.tooManyFiles(5)) })
        #expect(try await coordinator.read(PhotoQueries.fetchAll).count == 1)
        try await coordinator.close()
    }

    @Test(arguments: [FileImportCheckpoint.beforeCommit, .afterCommit])
    func attachmentAndOriginalShareOneCommit(checkpoint: FileImportCheckpoint) async throws {
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
        let source = try fixture.source(type: .jpeg)
        let result = try #require(
            await PhotoService(coordinator: coordinator).importFiles([source], for: owner).first)
        let expected = checkpoint == .afterCommit ? 1 : 0
        #expect(try await coordinator.read(PhotoQueries.fetchAll).count == expected)
        #expect(try await coordinator.read(FileAssetQueries.fetchAll).count == expected)
        #expect(
            try LibraryFiles.originalFiles(
                in: LibraryFiles.originals(
                    in: LibraryFiles.generation(info.generationID, in: fixture.root))
            ).count == expected)
        if expected == 1 {
            #expect(try result.outcome.get().item.kind == .photo)
        } else {
            #expect(result.outcome.failure != nil)
        }
        try await coordinator.close()
    }

    @Test
    func databaseAttachmentFailureLeavesNeitherAssetNorItem() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        let info = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql:
                    "CREATE TRIGGER rejectPhoto BEFORE INSERT ON libraryItem BEGIN SELECT RAISE(ABORT, 'fixture failure'); END"
            )
        }
        let source = try fixture.source(type: .png)
        let result = try #require(
            await PhotoService(coordinator: coordinator).importFiles([source], for: owner).first)
        #expect(result.outcome.failure != nil)
        #expect(try await coordinator.read(PhotoQueries.fetchAll).isEmpty)
        #expect(try await coordinator.read(FileAssetQueries.fetchAll).isEmpty)
        #expect(
            try LibraryFiles.originalFiles(
                in: LibraryFiles.originals(
                    in: LibraryFiles.generation(info.generationID, in: fixture.root))
            ).isEmpty)
        try await coordinator.close()
    }

    @Test
    func closedJobsRejectImportsAndStaleEditsButKeepOriginalsReadable() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        guard case .job(let id) = owners[1] else { throw NoteFixtureError() }
        let source = try fixture.source(type: .png)
        let service = PhotoService(coordinator: coordinator)
        let photo = try #require(await service.importFiles([source], for: owners[1]).first).outcome
            .get()
        var closure = JobTransitionDraft(stage: .completed)
        closure.outcome = "Finished"
        _ = try await JobService(coordinator: coordinator).transition(id, using: closure)
        var draft = PhotoDraft(item: photo.item)
        draft.caption = "Pending correction"
        await #expect(throws: JobError.closedJob) {
            try await service.save(draft, for: owners[1], editing: photo.id)
        }
        #expect(await service.importFiles([source], for: owners[1])[0].outcome.failure != nil)
        #expect(try await coordinator.read(PhotoQueries.fetchAll) == [photo])
        #expect(try await coordinator.read(FileAssetQueries.fetchAll) == [photo.asset])
        #expect(try await service.image(for: photo.asset.id, thumbnail: false).width == 12)
        _ = try await JobService(coordinator: coordinator).reopen(
            id, using: JobTransitionDraft(stage: .planned))
        #expect(
            try await service.save(draft, for: owners[1], editing: photo.id).caption
                == draft.caption)
        try await coordinator.close()
    }

    @Test
    func coverOwnershipAndWatchEditingPreserveReferencesAndLinkEditorRejectsPhotos() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        guard case .watch(let watchID) = owners[0] else { throw NoteFixtureError() }
        let source = try fixture.source(type: .png)
        let service = PhotoService(coordinator: coordinator)
        var photos: [PhotoRecord] = []
        for owner in owners {
            photos.append(try await service.importFiles([source], for: owner)[0].outcome.get())
        }
        var otherDraft = WatchDraft()
        otherDraft.name = "Other watch"
        let otherWatch = try await WatchService(coordinator: coordinator).save(
            otherDraft, editing: nil)
        let otherPhoto = try await service.importFiles([source], for: .watch(otherWatch.id))[0]
            .outcome.get()
        let link = try await ReferenceService(coordinator: coordinator).save(
            ReferenceFixture.draft, for: owners[0], editing: nil)
        for photoID in [photos[0].id, photos[1].id] {
            #expect(try await service.setCover(photoID, for: watchID).coverPhotoID == photoID)
        }
        for photoID in [photos[2].id, otherPhoto.id, link.id, UUID()] {
            await #expect(throws: PhotoError.invalidCover) {
                try await service.setCover(photoID, for: watchID)
            }
        }
        let watch = try #require(
            try await coordinator.read { try WatchQueries.fetch(watchID, in: $0) })
        var draft = WatchDraft(watch: watch)
        draft.name = "Renamed watch"
        #expect(
            try await WatchService(coordinator: coordinator).save(draft, editing: watchID)
                .coverPhotoID == photos[1].id)
        await #expect(throws: ReferenceError.notLink) {
            try await ReferenceService(coordinator: coordinator).save(
                ReferenceFixture.draft, for: owners[0], editing: photos[0].id)
        }
        await #expect(throws: PhotoError.ownerMismatch) {
            try await service.save(
                PhotoDraft(item: photos[0].item), for: owners[2], editing: photos[0].id)
        }
        let removedPhotoID = photos[1].id
        try await coordinator.mutate { db, _, _ in
            _ = try LibraryItem.deleteOne(db, key: removedPhotoID.uuidString)
        }
        #expect(
            try await coordinator.read { try WatchQueries.fetch(watchID, in: $0)?.coverPhotoID }
                == nil)
        #expect(try await coordinator.originalURL(for: photos[1].asset.id).isFileURL)
        try await coordinator.close()
    }

    @Test
    func missingOriginalReportsAnErrorAndDoesNotRemoveThePhoto() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        let source = try fixture.source(type: .png)
        let service = PhotoService(coordinator: coordinator)
        let photo = try await service.importFiles([source], for: owner)[0].outcome.get()
        try FileManager.default.removeItem(
            at: try await coordinator.originalURL(for: photo.asset.id))
        for thumbnail in [true, false] {
            await #expect(throws: (any Error).self) {
                try await service.image(for: photo.asset.id, thumbnail: thumbnail)
            }
        }
        #expect(try await coordinator.read(PhotoQueries.fetchAll) == [photo])
        try await coordinator.close()
    }

    @Test
    func forwardMigrationPreservesLinksRecordsAndOriginals() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        let before = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        let link = try await ReferenceService(coordinator: coordinator).save(
            ReferenceFixture.draft, for: owner, editing: nil)
        let source = try fixture.source(type: .png)
        let asset = try await coordinator.importOriginal(from: source, maximumByteCount: 1_000_000)
        let watches = try await coordinator.read(WatchQueries.fetchAll)
        try await coordinator.mutate { db, _, _ in try PhotoMigrationFixture.removePhotos(in: db) }
        try await coordinator.close()
        let reopened = LibraryCoordinator(root: fixture.root)
        let after = try await reopened.open()
        #expect(after.generationID != before.generationID)
        #expect(try await reopened.read(WatchQueries.fetchAll) == watches)
        #expect(try await reopened.read(LibraryItemQueries.fetchAll) == [link])
        #expect(try await reopened.read(FileAssetQueries.fetchAll) == [asset])
        #expect(
            try Data(contentsOf: try await reopened.originalURL(for: asset.id))
                == Data(contentsOf: source))
        try await reopened.close()
    }
}

nonisolated private extension Result where Success == PhotoRecord, Failure == any Error {
    var failure: PhotoError? {
        if case .failure(let error) = self { return error as? PhotoError }
        return nil
    }
}

nonisolated enum PhotoMigrationFixture {
    static func removePhotos(in db: Database) throws {
        try JobTaskMigrationFixture.removeTasks(in: db)
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v10-documents'")
        try db.execute(sql: "DROP TRIGGER watch_cover_insert")
        try db.execute(sql: "DROP TRIGGER watch_cover_update")
        try db.execute(sql: "ALTER TABLE watch DROP COLUMN coverPhotoID")
        try db.execute(
            sql: """
                CREATE TABLE libraryItem_links (
                    id TEXT PRIMARY KEY, watchID TEXT REFERENCES watch(id), jobID TEXT REFERENCES job(id),
                    caliberID TEXT REFERENCES caliber(id), kind TEXT NOT NULL CHECK(kind = 'Link'),
                    title TEXT NOT NULL CHECK(length(trim(title)) > 0), sourceURL TEXT NOT NULL,
                    sourceDescription TEXT NOT NULL, notes TEXT NOT NULL, createdAt DOUBLE NOT NULL,
                    updatedAt DOUBLE NOT NULL,
                    CHECK((watchID IS NOT NULL) + (jobID IS NOT NULL) + (caliberID IS NOT NULL) = 1))
                """)
        try db.execute(
            sql: """
                INSERT INTO libraryItem_links SELECT id, watchID, jobID, caliberID, kind, title,
                    sourceURL, sourceDescription, notes, createdAt, updatedAt FROM libraryItem WHERE kind = 'Link'
                """)
        try db.drop(table: "libraryItem")
        try db.rename(table: "libraryItem_links", to: "libraryItem")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v9-photos'")
    }
}
