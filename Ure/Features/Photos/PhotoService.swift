import CoreGraphics
import Foundation
import GRDB
import ImageIO

nonisolated enum PhotoError: LocalizedError, Equatable {
    case unavailableOwner
    case missingRecord
    case ownerMismatch
    case notPhoto
    case invalidCover
    case invalidTitle
    case fileImport(FileImportError)

    var errorDescription: String? {
        switch self {
        case .unavailableOwner: "This photo's owner is no longer available."
        case .missingRecord: "This photo is no longer available."
        case .ownerMismatch: "This photo belongs to another scope."
        case .notPhoto: "Choose a JPEG, PNG, or HEIC photo."
        case .invalidCover: "A cover must be a photo from this watch or one of its jobs."
        case .invalidTitle: "Enter a photo title. Your draft has been kept."
        case .fileImport(let error): error.localizedDescription
        }
    }
}

nonisolated struct PhotoService: Sendable {
    let coordinator: LibraryCoordinator
    var maximumByteCount: Int64 = FileImportService.defaultMaximumByteCount
    var maximumFileCount: Int = FileImportService.defaultMaximumFileCount

    func importFiles(_ sources: [URL], for owner: LibraryItemOwner) async -> [FileImportResult<
        PhotoRecord
    >] {
        let importer = FileImportService(
            coordinator: coordinator, maximumByteCount: maximumByteCount,
            maximumFileCount: maximumFileCount)
        let results = await importer.importFiles(sources) { db, asset, dependencies in
            try Self.requireWritableOwner(owner, in: db)
            guard asset.detectedType != .pdf else { throw PhotoError.notPhoto }
            var watchID: UUID?
            var jobID: UUID?
            var caliberID: UUID?
            switch owner {
            case .watch(let id): watchID = id
            case .job(let id): jobID = id
            case .caliber(let id): caliberID = id
            }
            var item = LibraryItem(
                id: dependencies.makeID(), watchID: watchID, jobID: jobID, caliberID: caliberID,
                kind: .photo, title: asset.originalFilename, sourceURL: "",
                sourceDescription: "", notes: "", createdAt: asset.importedAt,
                updatedAt: asset.importedAt)
            item.fileAssetID = asset.id
            item.photoStage = .unclassified
            try LibraryItemQueries.insert(item, in: db)
            return PhotoRecord(item: item, asset: asset)
        }
        return results.map { result in
            let outcome = result.outcome.mapError(Self.photoError)
            return FileImportResult(source: result.source, outcome: outcome)
        }
    }

    private static func photoError(_ error: any Error) -> any Error {
        if let error = error as? PhotoError { return error }
        if let error = error as? FileImportError, error == .unsupportedType {
            return PhotoError.notPhoto
        }
        if let error = error as? FileImportError { return PhotoError.fileImport(error) }
        return PhotoError.fileImport(.storageFailure(error.localizedDescription))
    }

    func save(_ draft: PhotoDraft, for owner: LibraryItemOwner, editing id: UUID) async throws
        -> LibraryItem
    {
        try await coordinator.mutate { db, _, dependencies in
            try Self.requireWritableOwner(owner, in: db)
            guard let existing = try LibraryItemQueries.fetch(id, in: db) else {
                throw PhotoError.missingRecord
            }
            guard existing.kind == .photo else { throw PhotoError.notPhoto }
            guard existing.belongs(to: owner) else { throw PhotoError.ownerMismatch }
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            let item = try draft.applying(to: existing, updatedAt: now)
            try LibraryItemQueries.update(item, in: db)
            return item
        }
    }

    func setCover(_ photoID: UUID?, for watchID: UUID) async throws -> WatchRecord {
        try await coordinator.mutate { db, _, dependencies in
            guard var watch = try WatchQueries.fetch(watchID, in: db) else {
                throw PhotoError.unavailableOwner
            }
            try RecordAccess.requireWatch(watchID, in: db)
            if let photoID {
                guard let item = try LibraryItemQueries.fetch(photoID, in: db), item.kind == .photo
                else {
                    throw PhotoError.invalidCover
                }
                var belongs = item.watchID == watchID
                if let jobID = item.jobID {
                    belongs = try JobQueries.fetch(jobID, in: db)?.watchID == watchID
                }
                guard belongs else { throw PhotoError.invalidCover }
            }
            watch.coverPhotoID = photoID
            watch.updatedAt = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            try WatchQueries.update(watch, in: db)
            return watch
        }
    }

    static func requireWritableOwner(_ owner: LibraryItemOwner, in db: Database) throws {
        switch owner {
        case .job(let id): _ = try JobService.requireOpenJob(id, in: db)
        case .watch(let id):
            guard try WatchQueries.fetch(id, in: db) != nil else {
                throw PhotoError.unavailableOwner
            }
            try RecordAccess.requireWatch(id, in: db)
        case .caliber(let id):
            guard try CaliberQueries.fetch(id, in: db) != nil else {
                throw PhotoError.unavailableOwner
            }
            try RecordAccess.requireCaliber(id, in: db)
        }
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

    func export(_ assetID: UUID, to destination: URL) async throws {
        try await coordinator.exportOriginal(assetID, to: destination)
    }
}
