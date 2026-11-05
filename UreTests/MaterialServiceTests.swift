import CoreGraphics
import Foundation
import GRDB
import PDFKit
import Testing

@testable import Ure

nonisolated struct MaterialServiceTests {
    @Test
    func everyScopeKeepsPhotosPDFsAndLinksAfterSourceRemovalAndRestart() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let photo = try fixture.source(type: .heic, name: "Å時計.wrong")
        let pdf = try DocumentFixture.source(in: fixture)
        let photoBytes = try Data(contentsOf: photo)
        let pdfBytes = try Data(contentsOf: pdf)
        let service = MaterialService(coordinator: coordinator)
        var saved: [MaterialRecord] = []
        for owner in owners {
            let results = await service.importFiles([photo, pdf], for: owner)
            let added = try results.map { try $0.outcome.get() }
            #expect(added.map(\.item.kind) == [.photo, .document])
            #expect(added.map(\.item.title) == [photo.lastPathComponent, pdf.lastPathComponent])
            #expect(added.allSatisfy { $0.item.belongs(to: owner) && $0.item.url == nil })
            #expect(added.map(\.asset?.detectedType) == [.heic, .pdf])
            let link = try await service.addLink(
                try #require(URL(string: "https://www.example.org/manual")), for: owner)
            #expect(link.kind == .link && link.title == "example.org")
            #expect(link.url == "https://www.example.org/manual" && link.fileAssetID == nil)
            saved += added + [MaterialRecord(item: link, asset: nil)]
        }
        try FileManager.default.removeItem(at: photo)
        try FileManager.default.removeItem(at: pdf)
        try await coordinator.close()

        let reopened = LibraryCoordinator(root: fixture.root)
        _ = try await reopened.open()
        let stored = try await reopened.read(MaterialQueries.fetchAll)
        #expect(byID(stored) == byID(saved))
        let service2 = MaterialService(coordinator: reopened)
        for record in saved {
            guard let asset = record.asset else { continue }
            let export = fixture.directory.appending(path: "export-\(record.id)")
            try await service2.export(asset.id, to: export)
            #expect(
                try Data(contentsOf: export) == (asset.detectedType == .pdf ? pdfBytes : photoBytes)
            )
            if record.item.kind == .photo {
                let image = try await service2.image(for: asset.id, thumbnail: false)
                #expect(image.width == 12 && image.height == 16)
            } else {
                #expect(try await service2.document(for: asset.id).pageCount == 3)
            }
            await #expect(throws: LibraryError.self) {
                try await service2.export(asset.id, to: fixture.root.appending(path: "export"))
            }
        }
        try await reopened.close()
    }

    @Test
    func mixedBatchAddsPhotosAndPDFsAndRejectsEachBadFileOnItsOwn() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        let sources = [
            try fixture.source(type: .png),
            try DocumentFixture.source(in: fixture),
            try fixture.file("\u{89}PNG broken", named: "broken.png"),
            try fixture.file("%PDF-1.7\nbroken", named: "broken.pdf"),
            try fixture.source(type: .pdf, encrypted: true),
            try fixture.source(type: .pdf, ownerPasswordOnly: true),
            try fixture.file("text", named: "text.jpg"),
            try fixture.file(String(repeating: "x", count: 20_000), named: "large.jpg"),
        ]
        let service = MaterialService(
            coordinator: coordinator, maximumByteCount: 10_000, maximumFileCount: 8)
        let results = await service.importFiles(sources, for: owner)
        #expect(try results[0].outcome.get().item.kind == .photo)
        #expect(try results[1].outcome.get().item.kind == .document)
        #expect(results[2].outcome.error != nil)
        #expect(results[3].outcome.error as? FileImportError == .corruptContent)
        #expect(results[4].outcome.error as? MaterialError == .protectedPDF)
        #expect(results[5].outcome.error as? MaterialError == .protectedPDF)
        #expect(results[6].outcome.error as? FileImportError == .unsupportedType)
        #expect(results[7].outcome.error as? FileImportError == .oversized(10_000))
        #expect(try await coordinator.read(MaterialQueries.fetchAll).count == 2)
        #expect(try await coordinator.read(FileAssetQueries.fetchAll).count == 2)
        let rejected = await service.importFiles(Array(repeating: sources[0], count: 9), for: owner)
        #expect(
            rejected.allSatisfy { $0.outcome.error as? FileImportError == .tooManyFiles(8) })
        #expect(try await coordinator.read(MaterialQueries.fetchAll).count == 2)
        try await coordinator.close()
    }

    @Test(arguments: [FileImportCheckpoint.beforeCommit, .afterCommit])
    func originalAndMaterialShareOneCommit(checkpoint: FileImportCheckpoint) async throws {
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
            await MaterialService(coordinator: coordinator).importFiles([source], for: owner).first)
        let expected = checkpoint == .afterCommit ? 1 : 0
        #expect(try await coordinator.read(MaterialQueries.fetchAll).count == expected)
        #expect(try await coordinator.read(FileAssetQueries.fetchAll).count == expected)
        #expect(
            try LibraryFiles.originalFiles(
                in: LibraryFiles.originals(
                    in: LibraryFiles.generation(info.generationID, in: fixture.root))
            ).count == expected)
        #expect((result.outcome.error == nil) == (expected == 1))
        try await coordinator.close()
    }

    @Test
    func databaseFailureLeavesNeitherOriginalNorMaterial() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        let info = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: """
                    CREATE TRIGGER rejectMaterial BEFORE INSERT ON libraryItem
                    BEGIN SELECT RAISE(ABORT, 'fixture failure'); END
                    """)
        }
        let result = try #require(
            await MaterialService(coordinator: coordinator).importFiles(
                [try DocumentFixture.source(in: fixture)], for: owner
            ).first)
        #expect(result.outcome.error != nil)
        #expect(try await coordinator.read(MaterialQueries.fetchAll).isEmpty)
        #expect(try await coordinator.read(FileAssetQueries.fetchAll).isEmpty)
        #expect(
            try LibraryFiles.originalFiles(
                in: LibraryFiles.originals(
                    in: LibraryFiles.generation(info.generationID, in: fixture.root))
            ).isEmpty)
        try await coordinator.close()
    }

    @Test(arguments: [
        ("https://example.org/manual.pdf", "example.org"),
        ("http://www.example.org", "example.org"),
        ("  https://shop.example.com/part?ref=0012-A  ", "shop.example.com"),
    ])
    func pastedAddressesBecomeLinksTitledByTheirHost(text: String, title: String) throws {
        let url = try WebLink.parse(text)
        #expect(WebLink.title(for: url) == title)
    }

    @Test(arguments: [
        ("https://", LinkError.invalidURL),
        ("ftp://example.org/file", LinkError.invalidURL),
        ("javascript://alert(1)", LinkError.invalidURL),
        ("www.example.org", LinkError.invalidURL),
        ("https://exa mple.org", LinkError.invalidURL),
        ("Omega 552 service guide", LinkError.notALink),
        ("", LinkError.notALink),
    ])
    func pastedTextThatIsNotACompleteAddressIsRejected(text: String, error: LinkError) {
        #expect(throws: error) { try WebLink.parse(text) }
    }

    @Test
    @MainActor
    func linksOpenOnlyThroughTheBrowserAndAStoredBadAddressStaysInvalid() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        let browser = MaterialBrowserSpy()
        var service = MaterialService(coordinator: coordinator, openBrowser: browser.open)
        let link = try await service.addLink(
            try #require(URL(string: "https://example.org/a")), for: owner)
        #expect(browser.urls.isEmpty)
        try service.openLink(link)
        #expect(browser.urls == [URL(string: "https://example.org/a")])
        service.openBrowser = { _ in false }
        #expect(throws: LinkError.browserUnavailable) { try service.openLink(link) }
        try await coordinator.mutate { db, _, _ in
            try db.execute(sql: "UPDATE libraryItem SET url = 'javascript:alert(1)'")
        }
        let stored = try #require(try await coordinator.read(LibraryItemQueries.fetchAll).first)
        #expect(throws: LinkError.invalidURL) { try service.openLink(stored) }
        try await coordinator.close()
    }

    @Test
    func renamingKeepsIdentityAndABlankTitleKeepsTheSavedOne() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(
            root: fixture.root,
            dependencies: LibraryDependencies(now: { Date(timeIntervalSince1970: 50) }))
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let service = MaterialService(coordinator: coordinator)
        let photo = try #require(
            await service.importFiles([try fixture.source(type: .png)], for: owners[0]).first
        ).outcome.get()
        try await service.rename(photo.id, to: "  Dial – Å時計 ", for: owners[0])
        var stored = try #require(
            try await coordinator.read { try LibraryItemQueries.fetch(photo.id, in: $0) })
        #expect(stored.title == "  Dial – Å時計 ")
        #expect(stored.createdAt == photo.item.createdAt && stored.fileAssetID == photo.asset?.id)
        #expect(
            try await coordinator.read { try SearchQueries.fetch("dial – å時計", in: $0) }.map(
                \.recordID) == [photo.id])
        try await service.rename(photo.id, to: " \n ", for: owners[0])
        stored = try #require(
            try await coordinator.read { try LibraryItemQueries.fetch(photo.id, in: $0) })
        #expect(stored.title == "  Dial – Å時計 ")
        await #expect(throws: MaterialError.ownerMismatch) {
            try await service.rename(photo.id, to: "Other", for: owners[1])
        }
        await #expect(throws: MaterialError.missingMaterial) {
            try await service.rename(UUID(), to: "Other", for: owners[0])
        }
        try await coordinator.close()
    }

    @Test
    func removedMaterialKeepsItsOriginalUntilTheLibraryOpensAgain() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let service = MaterialService(coordinator: coordinator)
        let source = try fixture.source(type: .png)
        let bytes = try Data(contentsOf: source)
        let photo = try #require(await service.importFiles([source], for: owners[0]).first)
            .outcome.get()
        let asset = try #require(photo.asset)
        let watch = try #require(try await coordinator.read(WatchQueries.fetchAll).first)
        try await service.setCover(photo.id, for: watch.id)
        try await service.rename(photo.id, to: "Needle photo", for: owners[0])
        let original = try await coordinator.originalURL(for: asset.id)

        let removed = try await service.remove(photo.id, from: owners[0])
        #expect(removed.coverWatchIDs == [watch.id])
        #expect(try await coordinator.read(MaterialQueries.fetchAll).isEmpty)
        #expect(
            try await coordinator.read { try WatchQueries.fetch(watch.id, in: $0) }?.coverPhotoID
                == nil)
        #expect(
            try await coordinator.read { try SearchQueries.fetch("Needle photo", in: $0) }.isEmpty)
        #expect(try await coordinator.read(FileAssetQueries.fetchAll) == [asset])
        #expect(try Data(contentsOf: original) == bytes)

        try await service.restore(removed)
        let back = try await coordinator.read(MaterialQueries.fetchAll)
        #expect(back.map(\.item) == [removed.item] && back.first?.asset == asset)
        #expect(
            try await coordinator.read { try WatchQueries.fetch(watch.id, in: $0) }?.coverPhotoID
                == photo.id)
        #expect(
            try await coordinator.read { try SearchQueries.fetch("Needle photo", in: $0) }.map(
                \.recordID) == [photo.id])

        _ = try await service.remove(photo.id, from: owners[0])
        let link = try await service.addLink(
            try #require(URL(string: "https://example.org")), for: owners[2])
        _ = try await service.remove(link.id, from: owners[2])
        try await coordinator.close()
        #expect(try Data(contentsOf: original) == bytes)

        let reopened = LibraryCoordinator(root: fixture.root)
        _ = try await reopened.open()
        #expect(try await reopened.read(FileAssetQueries.fetchAll).isEmpty)
        #expect(try await reopened.read(MaterialQueries.fetchAll).isEmpty)
        let generation = original.deletingLastPathComponent().deletingLastPathComponent()
        #expect(
            try LibraryFiles.originalFiles(in: LibraryFiles.originals(in: generation)).isEmpty)
        await #expect(throws: MaterialError.missingMaterial) {
            try await MaterialService(coordinator: reopened).restore(removed)
        }
        try await reopened.close()
    }

    @Test
    func anOriginalThatOtherMaterialStillUsesStaysAfterTheLibraryOpensAgain() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let service = MaterialService(coordinator: coordinator)
        let source = try fixture.source(type: .png)
        let photo = try #require(await service.importFiles([source], for: owners[0]).first)
            .outcome.get()
        let asset = try #require(photo.asset)
        let shared = Ure.LibraryItem(
            id: UUID(), owner: owners[2], kind: .photo, title: "Shared bytes", url: nil,
            fileAssetID: asset.id, createdAt: photo.item.createdAt,
            updatedAt: photo.item.updatedAt)
        try await coordinator.mutate { db, _, _ in try LibraryItemQueries.insert(shared, in: db) }
        _ = try await service.remove(photo.id, from: owners[0])
        try await coordinator.close()
        let reopened = LibraryCoordinator(root: fixture.root)
        _ = try await reopened.open()
        #expect(try await reopened.read(LibraryItemQueries.fetchAll) == [shared])
        #expect(
            try Data(contentsOf: try await reopened.originalURL(for: asset.id))
                == Data(contentsOf: source))
        try await reopened.close()
    }

    @Test
    func failedRemovalKeepsTheMaterialAndItsCover() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let service = MaterialService(coordinator: coordinator)
        let photo = try #require(
            await service.importFiles([try fixture.source(type: .png)], for: owners[0]).first
        ).outcome.get()
        let watch = try #require(try await coordinator.read(WatchQueries.fetchAll).first)
        try await service.setCover(photo.id, for: watch.id)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: """
                    CREATE TRIGGER failRemoval BEFORE DELETE ON libraryItem
                    BEGIN SELECT RAISE(ABORT, 'injected'); END
                    """)
        }
        await #expect(throws: DatabaseError.self) {
            try await service.remove(photo.id, from: owners[0])
        }
        #expect(try await coordinator.read(MaterialQueries.fetchAll).map(\.id) == [photo.id])
        #expect(
            try await coordinator.read { try WatchQueries.fetch(watch.id, in: $0) }?.coverPhotoID
                == photo.id)
        await #expect(throws: MaterialError.ownerMismatch) {
            try await service.remove(photo.id, from: owners[1])
        }
        try await coordinator.close()
    }

    @Test
    func archivedOwnersRejectChangesAndKeepTheirOriginals() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let service = MaterialService(coordinator: coordinator)
        let source = try fixture.source(type: .png)
        var saved: [MaterialRecord] = []
        for owner in owners {
            saved.append(
                try #require(await service.importFiles([source], for: owner).first).outcome.get())
        }
        let removedLink = try await service.remove(
            try await service.addLink(
                try #require(URL(string: "https://example.org")), for: owners[1]
            ).id,
            from: owners[1])
        let job = try #require(try await coordinator.read(JobQueries.fetchAll).first)
        // A Done job's material still changes. Only an archived job's does not.
        _ = try await JobService(coordinator: coordinator).setStage(job.id, to: .done)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: "UPDATE job SET archivedAt = 1 WHERE id = ?", arguments: [job.id.uuidString])
        }
        _ = try await ArchiveService(coordinator: coordinator).setWatch(
            try #require(job.watchID), archived: true)
        let caliber = try #require(try await coordinator.read(CaliberQueries.fetchAll).first)
        _ = try await ArchiveService(coordinator: coordinator).setCaliber(
            caliber.id, archived: true)
        let url = try #require(URL(string: "https://example.org/b"))
        for (owner, record) in zip(owners, saved) {
            let imports = await service.importFiles([source], for: owner)
            #expect(try #require(imports.first).outcome.error != nil)
            await #expect(throws: (any Error).self) { try await service.addLink(url, for: owner) }
            await #expect(throws: (any Error).self) {
                try await service.rename(record.id, to: "Changed", for: owner)
            }
            await #expect(throws: (any Error).self) {
                try await service.remove(record.id, from: owner)
            }
            let asset = try #require(record.asset)
            #expect(
                try Data(contentsOf: try await coordinator.originalURL(for: asset.id))
                    == Data(contentsOf: source))
        }
        await #expect(throws: (any Error).self) { try await service.restore(removedLink) }
        #expect(try await coordinator.read(MaterialQueries.fetchAll).count == 3)
        #expect(
            Set(try await coordinator.read(MaterialQueries.fetchAll).map(\.item.title)) == [
                source.lastPathComponent
            ])
        try await coordinator.close()
    }

    @Test
    func aCoverIsAPhotoFromTheWatchOrOneOfItsJobs() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let service = MaterialService(coordinator: coordinator)
        let photo = try fixture.source(type: .png)
        let jobPhoto = try #require(await service.importFiles([photo], for: owners[1]).first)
            .outcome.get()
        let caliberPhoto = try #require(await service.importFiles([photo], for: owners[2]).first)
            .outcome.get()
        let pdf = try #require(
            await service.importFiles([try DocumentFixture.source(in: fixture)], for: owners[0])
                .first
        ).outcome.get()
        let watch = try #require(try await coordinator.read(WatchQueries.fetchAll).first)
        try await service.setCover(jobPhoto.id, for: watch.id)
        #expect(
            try await coordinator.read { try WatchQueries.fetch(watch.id, in: $0) }?.coverPhotoID
                == jobPhoto.id)
        for invalid in [caliberPhoto.id, pdf.id, UUID()] {
            await #expect(throws: MaterialError.invalidCover) {
                try await service.setCover(invalid, for: watch.id)
            }
        }
        try await service.setCover(nil, for: watch.id)
        #expect(
            try await coordinator.read { try WatchQueries.fetch(watch.id, in: $0) }?.coverPhotoID
                == nil)
        try await coordinator.close()
    }

    @Test
    func aMissingOriginalReportsAnErrorAndKeepsTheMaterial() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        let service = MaterialService(coordinator: coordinator)
        let results = await service.importFiles(
            [try fixture.source(type: .png), try DocumentFixture.source(in: fixture)], for: owner)
        let added = try results.map { try $0.outcome.get() }
        for record in added {
            let asset = try #require(record.asset)
            try FileManager.default.removeItem(at: try await coordinator.originalURL(for: asset.id))
        }
        await #expect(throws: (any Error).self) {
            try await service.image(for: try #require(added[0].asset).id, thumbnail: true)
        }
        await #expect(throws: (any Error).self) {
            try await service.document(for: try #require(added[1].asset).id)
        }
        let stored = try await coordinator.read(MaterialQueries.fetchAll)
        #expect(byID(stored) == byID(added))
        try await coordinator.close()
    }
}

nonisolated private func byID(_ records: [MaterialRecord]) -> [MaterialRecord] {
    records.sorted { $0.id.uuidString < $1.id.uuidString }
}

extension Result {
    nonisolated var error: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

@MainActor
final class MaterialBrowserSpy {
    private(set) var urls: [URL] = []
    var succeeds = true

    func open(_ url: URL) -> Bool {
        urls.append(url)
        return succeeds
    }
}

nonisolated enum ReferenceFixture {
    static func owners(_ coordinator: LibraryCoordinator) async throws -> [LibraryItemOwner] {
        try await NoteFixture.owners(coordinator)
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

// Adds material the way the Material section does, then gives it a title.
nonisolated enum MaterialFixture {
    static func link(
        titled title: String, url: String = "https://example.org/manual.pdf",
        for owner: LibraryItemOwner, in coordinator: LibraryCoordinator
    ) async throws -> Ure.LibraryItem {
        let service = MaterialService(coordinator: coordinator)
        let item = try await service.addLink(try #require(URL(string: url)), for: owner)
        try await service.rename(item.id, to: title, for: owner)
        return try #require(
            try await coordinator.read { try LibraryItemQueries.fetch(item.id, in: $0) })
    }

    static func file(
        _ source: URL, titled title: String? = nil, for owner: LibraryItemOwner,
        in coordinator: LibraryCoordinator
    ) async throws -> MaterialRecord {
        let service = MaterialService(coordinator: coordinator)
        let record = try #require(await service.importFiles([source], for: owner).first).outcome
            .get()
        guard let title else { return record }
        try await service.rename(record.id, to: title, for: owner)
        let item = try #require(
            try await coordinator.read { try LibraryItemQueries.fetch(record.id, in: $0) })
        return MaterialRecord(item: item, asset: record.asset)
    }
}
