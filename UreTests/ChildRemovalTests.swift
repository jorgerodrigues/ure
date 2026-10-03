import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct ChildRemovalTests {
    @Test
    func removedTaskClearsLinksAndCompactsOrderButKeepsPartsAndActivity() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let other = try await JobTaskFixture.job(coordinator)
        let part = try await PartService(coordinator: coordinator).save(
            PartFixture.draft(), for: job.id, editing: nil)
        let tasks = JobTaskService(coordinator: coordinator)
        var draft = JobTaskFixture.draft(.done)
        draft.partIDs = [part.id]
        let removed = try await tasks.save(draft, for: job.id, editing: nil)
        let survivor = try await tasks.save(JobTaskFixture.draft(.toDo), for: job.id, editing: nil)
        let events = try await coordinator.read(ActivityQueries.fetchAll)
        let removal = ChildRemovalService(coordinator: coordinator)
        await #expect(throws: RemovalError.scopeMismatch) {
            try await removal.removeTask(removed.id, for: other.id, confirmedPartIDs: [part.id])
        }
        await #expect(throws: RemovalError.changedLinks) {
            try await removal.removeTask(removed.id, for: job.id, confirmedPartIDs: [])
        }
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql:
                    "CREATE TRIGGER failTaskRemoval BEFORE DELETE ON jobTask BEGIN SELECT RAISE(ABORT, 'injected'); END"
            )
        }
        await #expect(throws: DatabaseError.self) {
            try await removal.removeTask(removed.id, for: job.id, confirmedPartIDs: [part.id])
        }
        #expect(
            try await coordinator.read { try TaskPartQueries.linked(to: removed.id, in: $0) }.count
                == 1)
        #expect(
            try await coordinator.read { try JobTaskQueries.fetch(removed.id, in: $0) } == removed)
        try await coordinator.mutate { db, _, _ in
            try db.execute(sql: "DROP TRIGGER failTaskRemoval")
        }
        let remaining = try await removal.removeTask(
            removed.id, for: job.id, confirmedPartIDs: [part.id])
        #expect(remaining.map(\.id) == [survivor.id] && remaining.first?.position == 0)
        #expect(
            try await coordinator.read { try TaskPartQueries.linked(to: removed.id, in: $0) }
                .isEmpty)
        #expect(try await coordinator.read { try PartQueries.fetch(part.id, in: $0) } == part)
        #expect(try await coordinator.read(ActivityQueries.fetchAll) == events)
        let timeline = try await coordinator.read { try JobTimelineQueries.fetch(job.id, in: $0) }
        #expect(
            timeline.contains {
                $0.subject == removed.title && $0.source == nil && $0.unavailableSource != nil
            })
        try await coordinator.close()
    }

    @Test
    func noteAndLinkRemovalUpdatesSearchAndClosedOrArchivedOwnersRejectRemoval() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owners = try await NoteFixture.owners(coordinator)
        let job = try #require(try await coordinator.read(JobQueries.fetchAll).first)
        let caliber = try #require(try await coordinator.read(CaliberQueries.fetchAll).first)
        let removal = ChildRemovalService(coordinator: coordinator)
        for owner in owners {
            var draft = NoteDraft()
            draft.title = "Needle note"
            let note = try await NoteService(coordinator: coordinator).save(
                draft, for: owner, editing: nil)
            let itemOwner: LibraryItemOwner
            switch owner {
            case .watch(let id): itemOwner = .watch(id)
            case .job(let id): itemOwner = .job(id)
            case .caliber(let id): itemOwner = .caliber(id)
            }
            let link = try await ReferenceService(coordinator: coordinator).save(
                ReferenceFixture.draft, for: itemOwner, editing: nil)
            try await removal.removeNote(note.id, for: owner)
            try await removal.removeItem(link.id, for: itemOwner, kind: .link)
            #expect(try await coordinator.read { try NoteQueries.fetch(note.id, in: $0) } == nil)
            #expect(
                try await coordinator.read { try LibraryItemQueries.fetch(link.id, in: $0) } == nil)
        }
        #expect(
            try await coordinator.read {
                try SearchQueries.fetch("Needle note", includeArchived: true, in: $0)
            }.isEmpty)
        var draft = NoteDraft()
        draft.title = "Kept note"
        let jobNote = try await NoteService(coordinator: coordinator).save(
            draft, for: .job(job.id), editing: nil)
        let caliberNote = try await NoteService(coordinator: coordinator).save(
            draft, for: .caliber(caliber.id), editing: nil)
        var closure = JobTransitionDraft(stage: .cancelled)
        closure.cancellationReason = "Retain records"
        _ = try await JobService(coordinator: coordinator).transition(job.id, using: closure)
        await #expect(throws: JobError.closedJob) {
            try await removal.removeNote(jobNote.id, for: .job(job.id))
        }
        _ = try await ArchiveService(coordinator: coordinator).setCaliber(
            caliber.id, archived: true)
        await #expect(throws: ArchiveError.archived) {
            try await removal.removeNote(caliberNote.id, for: .caliber(caliber.id))
        }
        #expect(try await coordinator.read(NoteQueries.fetchAll).count == 2)
        try await coordinator.close()
    }

    @Test
    func cleanupFailureKeepsCommittedRemovalAndRestartRetriesWithoutRemovingSharedBytes()
        async throws
    {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(
            root: fixture.root,
            dependencies: LibraryDependencies(removeOriginal: { _ in throw RemovalFixtureFailure() }
            ))
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let source = try fixture.source(type: .png)
        let bytes = try Data(contentsOf: source)
        let photo = try #require(
            await PhotoService(coordinator: coordinator).importFiles([source], for: owners[0]).first
        ).outcome.get()
        let watch = try #require(try await coordinator.read(WatchQueries.fetchAll).first)
        _ = try await PhotoService(coordinator: coordinator).setCover(photo.id, for: watch.id)
        let original = try await coordinator.originalURL(for: photo.asset.id)
        let removal = ChildRemovalService(coordinator: coordinator)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql:
                    "CREATE TRIGGER failRemoval BEFORE DELETE ON libraryItem BEGIN SELECT RAISE(ABORT, 'injected'); END"
            )
        }
        await #expect(throws: DatabaseError.self) {
            try await removal.removeItem(photo.id, for: owners[0], kind: .photo)
        }
        #expect(try Data(contentsOf: original) == bytes)
        #expect(
            try await coordinator.read { try WatchQueries.fetch(watch.id, in: $0)?.coverPhotoID }
                == photo.id)
        try await coordinator.mutate { db, _, _ in try db.execute(sql: "DROP TRIGGER failRemoval") }
        try await removal.removeItem(photo.id, for: owners[0], kind: .photo)
        #expect(
            try await coordinator.read { try LibraryItemQueries.fetch(photo.id, in: $0) } == nil)
        #expect(
            try await coordinator.read { try FileAssetQueries.fetch(photo.asset.id, in: $0) } == nil
        )
        #expect(
            try await coordinator.read { try WatchQueries.fetch(watch.id, in: $0)?.coverPhotoID }
                == nil)
        #expect(try Data(contentsOf: original) == bytes)
        let retained = try #require(
            await PhotoService(coordinator: coordinator).importFiles([source], for: owners[0]).first
        ).outcome.get()
        let retainedURL = try await coordinator.originalURL(for: retained.asset.id)
        let shared = LibraryItem(
            id: UUID(), watchID: nil, jobID: nil,
            caliberID: try #require(try await coordinator.read(CaliberQueries.fetchAll).first).id,
            kind: .photo, title: "Shared bytes", sourceURL: "", sourceDescription: "", notes: "",
            createdAt: retained.item.createdAt, updatedAt: retained.item.updatedAt,
            fileAssetID: retained.asset.id, photoStage: .unclassified)
        try await coordinator.mutate { db, _, _ in try LibraryItemQueries.insert(shared, in: db) }
        try await removal.removeItem(retained.id, for: owners[0], kind: .photo)
        #expect(
            try await coordinator.read { try FileAssetQueries.fetch(retained.asset.id, in: $0) }
                == retained.asset)
        try await coordinator.close()
        let restarted = LibraryCoordinator(root: fixture.root)
        _ = try await restarted.open()
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(try Data(contentsOf: retainedURL) == bytes)
        #expect(try await restarted.read(LibraryItemQueries.fetchAll) == [shared])
        try await restarted.close()
    }

    @Test
    func archivedAndClosedFileOwnersRejectEditsImportsAndRemovalWithoutLosingBytes() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let source = try fixture.source(type: .png)
        let pdf = try DocumentFixture.source(in: fixture)
        let photos = PhotoService(coordinator: coordinator)
        let documents = DocumentService(coordinator: coordinator)
        let removal = ChildRemovalService(coordinator: coordinator)
        var savedPhotos: [PhotoRecord] = []
        var savedDocuments: [DocumentRecord] = []
        for owner in owners {
            savedPhotos.append(
                try #require(await photos.importFiles([source], for: owner).first).outcome.get())
            savedDocuments.append(
                try #require(await documents.importFiles([pdf], for: owner).first).outcome.get())
        }
        let job = try #require(try await coordinator.read(JobQueries.fetchAll).first)
        let caliber = try #require(try await coordinator.read(CaliberQueries.fetchAll).first)
        var closure = JobTransitionDraft(stage: .cancelled)
        closure.cancellationReason = "Retain files"
        _ = try await JobService(coordinator: coordinator).transition(job.id, using: closure)
        for index in owners.indices {
            let owner = owners[index]
            if case .watch(let id) = owner {
                _ = try await ArchiveService(coordinator: coordinator).setWatch(id, archived: true)
            }
            if case .caliber = owner {
                _ = try await ArchiveService(coordinator: coordinator).setCaliber(
                    caliber.id, archived: true)
            }
            let photo = savedPhotos[index]
            let document = savedDocuments[index]
            await #expect(throws: (any Error).self) {
                try await photos.save(PhotoDraft(item: photo.item), for: owner, editing: photo.id)
            }
            await #expect(throws: (any Error).self) {
                try await documents.save(
                    DocumentDraft(item: document.item), for: owner, editing: document.id)
            }
            await #expect(throws: (any Error).self) {
                try await removal.removeItem(photo.id, for: owner, kind: .photo)
            }
            await #expect(throws: (any Error).self) {
                try await removal.removeItem(document.id, for: owner, kind: .document)
            }
            let imports = await photos.importFiles([source], for: owner)
            if case .success = try #require(imports.first).outcome {
                Issue.record("Archived or closed imports must fail")
            }
            let pdfImports = await documents.importFiles([pdf], for: owner)
            if case .success = try #require(pdfImports.first).outcome {
                Issue.record("Archived or closed imports must fail")
            }
            #expect(
                try Data(contentsOf: try await coordinator.originalURL(for: photo.asset.id))
                    == Data(contentsOf: source))
            #expect(
                try Data(contentsOf: try await coordinator.originalURL(for: document.asset.id))
                    == Data(contentsOf: pdf))
        }
        #expect(try await coordinator.read(FileAssetQueries.fetchAll).count == 6)
        await #expect(throws: ArchiveError.archived) {
            try await photos.setCover(savedPhotos[0].id, for: job.watchID)
        }
        try await coordinator.close()
    }

    @Test
    func PDFRemovalKeepsOriginalOnRollbackAndRemovesUnreferencedBytesAfterCommit() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let source = try DocumentFixture.source(in: fixture)
        let document = try #require(
            await DocumentService(coordinator: coordinator).importFiles([source], for: owners[2])
                .first
        ).outcome.get()
        let original = try await coordinator.originalURL(for: document.asset.id)
        await #expect(throws: RemovalError.scopeMismatch) {
            try await ChildRemovalService(coordinator: coordinator).removeItem(
                document.id, for: owners[0], kind: .document)
        }
        #expect(FileManager.default.fileExists(atPath: original.path))
        try await ChildRemovalService(coordinator: coordinator).removeItem(
            document.id, for: owners[2], kind: .document)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(try await coordinator.read(FileAssetQueries.fetchAll).isEmpty)
        try await coordinator.close()
    }
}

nonisolated struct RemovalFixtureFailure: Error {}
