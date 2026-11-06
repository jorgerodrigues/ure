import AppKit
import CoreGraphics
import Foundation
import GRDB
import ImageIO
import PDFKit

nonisolated enum MaterialError: LocalizedError, Equatable {
    case missingMaterial
    case ownerMismatch
    case notPhoto
    case notPDF
    case protectedPDF
    case corruptPDF
    case invalidCover

    var errorDescription: String? {
        switch self {
        case .missingMaterial: "This material is no longer available."
        case .ownerMismatch: "This material belongs to another record."
        case .notPhoto: "Choose a JPEG, PNG, or HEIC photo."
        case .notPDF: "Choose a PDF document."
        case .protectedPDF: "Protected PDF files are not supported. Choose an unprotected copy."
        case .corruptPDF: "This PDF is incomplete or cannot be read. Choose a valid copy."
        case .invalidCover: "A cover must be a photo from this watch or one of its jobs."
        }
    }
}

// What Undo needs to put removed material back: the material itself and the watches whose
// cover it was.
nonisolated struct RemovedMaterial: Equatable, Sendable {
    let item: LibraryItem
    let coverWatchIDs: [UUID]
}

nonisolated struct MaterialService: Sendable {
    let coordinator: LibraryCoordinator
    var maximumByteCount: Int64 = FileImportService.defaultMaximumByteCount
    var maximumFileCount: Int = FileImportService.defaultMaximumFileCount
    var openBrowser: @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }

    // Imports photos and PDFs. Each file becomes material on the owner, titled by its filename.
    func importFiles(_ sources: [URL], for owner: LibraryItemOwner) async
        -> [FileImportResult<MaterialRecord>]
    {
        let importer = FileImportService(
            coordinator: coordinator, maximumByteCount: maximumByteCount,
            maximumFileCount: maximumFileCount)
        let results = await importer.importFiles(sources, validate: Self.validateOriginal) {
            db, asset, dependencies in
            try RecordAccess.requireOwner(owner, in: db)
            let kind: LibraryItemKind = asset.detectedType == .pdf ? .document : .photo
            let item = LibraryItem(
                id: dependencies.makeID(), owner: owner, kind: kind,
                title: asset.originalFilename, url: nil, fileAssetID: asset.id,
                createdAt: asset.importedAt, updatedAt: asset.importedAt)
            try LibraryItemQueries.insert(item, in: db)
            return MaterialRecord(item: item, asset: asset)
        }
        return results.map { result in
            FileImportResult(
                source: result.source, outcome: result.outcome.mapError(Self.importError))
        }
    }

    private static func validateOriginal(_ url: URL, _ asset: FileAsset) throws {
        guard asset.detectedType == .pdf else { return }
        guard let document = CGPDFDocument(url as CFURL) else { throw MaterialError.corruptPDF }
        guard !document.isEncrypted else { throw MaterialError.protectedPDF }
    }

    private static func importError(_ error: any Error) -> any Error {
        if let error = error as? FileImportError, error == .encryptedPDF {
            return MaterialError.protectedPDF
        }
        return error
    }

    func addLink(_ url: URL, for owner: LibraryItemOwner) async throws -> LibraryItem {
        try await coordinator.mutate { db, _, dependencies in
            try RecordAccess.requireOwner(owner, in: db)
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            let item = LibraryItem(
                id: dependencies.makeID(), owner: owner, kind: .link,
                title: WebLink.title(for: url), url: url.absoluteString, fileAssetID: nil,
                createdAt: now, updatedAt: now)
            try LibraryItemQueries.insert(item, in: db)
            return item
        }
    }

    // A blank title keeps the saved one, so clearing the field never leaves material untitled.
    @discardableResult
    func rename(_ id: UUID, to title: String, for owner: LibraryItemOwner) async throws
        -> Revision<LibraryItem>
    {
        try await coordinator.mutate { db, _, dependencies in
            try RecordAccess.requireOwner(owner, in: db)
            guard var item = try LibraryItemQueries.fetch(id, in: db) else {
                throw MaterialError.missingMaterial
            }
            guard item.belongs(to: owner) else { throw MaterialError.ownerMismatch }
            let saved = item
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                title != item.title
            else { return Revision(before: saved, after: saved) }
            item.title = title
            item.updatedAt = Date(
                timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            try LibraryItemQueries.update(item, in: db)
            return Revision(before: saved, after: item)
        }
    }

    // Removes material and clears any cover it was. The original file stays, because Undo can
    // bring the material back. The next library open deletes it.
    func remove(_ id: UUID, from owner: LibraryItemOwner) async throws -> RemovedMaterial {
        try await coordinator.mutate { db, _, dependencies in
            try RecordAccess.requireOwner(owner, in: db)
            guard let item = try LibraryItemQueries.fetch(id, in: db) else {
                throw MaterialError.missingMaterial
            }
            guard item.belongs(to: owner) else { throw MaterialError.ownerMismatch }
            let covers = try String.fetchAll(
                db, sql: "SELECT id FROM watch WHERE coverPhotoID = ? ORDER BY id",
                arguments: [id.uuidString]
            ).compactMap(UUID.init(uuidString:))
            _ = try item.delete(db)
            if let assetID = item.fileAssetID {
                try MaterialQueries.markRemoved(
                    assetID,
                    at: Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970),
                    in: db)
            }
            return RemovedMaterial(item: item, coverWatchIDs: covers)
        }
    }

    // Puts removed material back with its file, and makes it the cover again where no other
    // cover was chosen since.
    @discardableResult
    func restore(_ removed: RemovedMaterial) async throws -> MaterialRecord {
        try await coordinator.mutate { db, _, _ in
            guard let owner = removed.item.owner else { throw MaterialError.missingMaterial }
            try RecordAccess.requireOwner(owner, in: db)
            let asset = try removed.item.fileAssetID.flatMap {
                try FileAssetQueries.fetch($0, in: db)
            }
            if let existing = try LibraryItemQueries.fetch(removed.item.id, in: db) {
                return MaterialRecord(item: existing, asset: asset)
            }
            if let assetID = removed.item.fileAssetID {
                guard asset != nil else { throw MaterialError.missingMaterial }
                try MaterialQueries.unmarkRemoved(assetID, in: db)
            }
            try LibraryItemQueries.insert(removed.item, in: db)
            for watchID in removed.coverWatchIDs {
                try db.execute(
                    sql: "UPDATE watch SET coverPhotoID = ? WHERE id = ? AND coverPhotoID IS NULL",
                    arguments: [removed.item.id.uuidString, watchID.uuidString])
            }
            return MaterialRecord(item: removed.item, asset: asset)
        }
    }

    func setCover(_ photoID: UUID?, for watchID: UUID) async throws {
        try await coordinator.mutate { db, _, dependencies in
            guard var watch = try WatchQueries.fetch(watchID, in: db) else {
                throw ArchiveError.missingRecord
            }
            try RecordAccess.requireWatch(watchID, in: db)
            if let photoID {
                guard let item = try LibraryItemQueries.fetch(photoID, in: db), item.kind == .photo
                else { throw MaterialError.invalidCover }
                var belongs = item.watchID == watchID
                if let jobID = item.jobID {
                    belongs = try JobQueries.fetch(jobID, in: db)?.watchID == watchID
                }
                guard belongs else { throw MaterialError.invalidCover }
            }
            watch.coverPhotoID = photoID
            watch.updatedAt = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            try WatchQueries.update(watch, in: db)
        }
    }

    @MainActor
    func openLink(_ item: LibraryItem) throws {
        guard item.kind == .link, let url = WebLink.url(from: item.url ?? "") else {
            throw LinkError.invalidURL
        }
        guard openBrowser(url) else { throw LinkError.browserUnavailable }
    }

    func image(for assetID: UUID, thumbnail: Bool) async throws -> CGImage {
        let original = try await coordinator.photoOriginal(for: assetID)
        let maximum = thumbnail ? 256 : original.maximumPixelSize
        return try await Self.decodeImage(at: original.url, maximumPixelSize: maximum)
    }

    @concurrent
    private static func decodeImage(at url: URL, maximumPixelSize: Int) async throws -> CGImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw FileImportError.corruptContent
        }
        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw FileImportError.corruptContent
        }
        try Task.checkCancellation()
        return image
    }

    func document(for assetID: UUID) async throws -> sending PDFDocument {
        let bytes = try await coordinator.documentBytes(for: assetID)
        return try await Self.decodeDocument(bytes)
    }

    @concurrent
    private static func decodeDocument(_ bytes: Data) async throws -> sending PDFDocument {
        try Task.checkCancellation()
        guard let document = PDFDocument(data: bytes) else { throw MaterialError.corruptPDF }
        guard !document.isEncrypted, !document.isLocked else { throw MaterialError.protectedPDF }
        guard document.pageCount > 0 else { throw MaterialError.corruptPDF }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw MaterialError.corruptPDF }
            for annotation in page.annotations where annotation.type == "Widget" {
                annotation.isReadOnly = true
            }
        }
        return document
    }

    func export(_ assetID: UUID, to destination: URL) async throws {
        try await coordinator.exportOriginal(assetID, to: destination)
    }
}
