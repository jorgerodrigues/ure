import AppKit
import CoreGraphics
import Foundation
import GRDB
import PDFKit

nonisolated enum DocumentError: LocalizedError, Equatable {
    case unavailableOwner
    case missingRecord
    case ownerMismatch
    case notPDF
    case protectedPDF
    case corruptPDF
    case fileImport(FileImportError)

    var errorDescription: String? {
        switch self {
        case .unavailableOwner:
            "This document's owner is no longer available. Your draft has been kept."
        case .missingRecord: "This document is no longer available. Your draft has been kept."
        case .ownerMismatch: "This document belongs to another scope. Your draft has been kept."
        case .notPDF: "Choose a PDF document."
        case .protectedPDF: "Protected PDF files are not supported. Choose an unprotected copy."
        case .corruptPDF: "This PDF is incomplete or cannot be read. Choose a valid copy."
        case .fileImport(let error): error.localizedDescription
        }
    }
}

nonisolated struct DocumentService: Sendable {
    let coordinator: LibraryCoordinator
    var maximumByteCount: Int64 = FileImportService.defaultMaximumByteCount
    var maximumFileCount: Int = FileImportService.defaultMaximumFileCount
    var openBrowser: @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }

    func importFiles(_ sources: [URL], for owner: LibraryItemOwner) async -> [FileImportResult<
        DocumentRecord
    >] {
        let importer = FileImportService(
            coordinator: coordinator, maximumByteCount: maximumByteCount,
            maximumFileCount: maximumFileCount)
        let results = await importer.importFiles(sources, validate: Self.validateOriginal) {
            db, asset, dependencies in
            try Self.requireWritableOwner(owner, in: db)
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
                kind: .document, title: asset.originalFilename, sourceURL: "",
                sourceDescription: "",
                notes: "", createdAt: asset.importedAt, updatedAt: asset.importedAt)
            item.fileAssetID = asset.id
            try LibraryItemQueries.insert(item, in: db)
            return DocumentRecord(item: item, asset: asset)
        }
        return results.map { result in
            FileImportResult(
                source: result.source, outcome: result.outcome.mapError(Self.documentError))
        }
    }

    private static func validateOriginal(_ url: URL, _ asset: FileAsset) throws {
        guard asset.detectedType == .pdf else { throw DocumentError.notPDF }
        guard let document = CGPDFDocument(url as CFURL) else { throw DocumentError.corruptPDF }
        guard !document.isEncrypted else { throw DocumentError.protectedPDF }
    }

    private static func documentError(_ error: any Error) -> any Error {
        if let error = error as? DocumentError { return error }
        if let error = error as? FileImportError {
            switch error {
            case .unsupportedType: return DocumentError.notPDF
            case .encryptedPDF: return DocumentError.protectedPDF
            case .corruptContent: return DocumentError.corruptPDF
            default: return DocumentError.fileImport(error)
            }
        }
        return error
    }

    func save(_ draft: DocumentDraft, for owner: LibraryItemOwner, editing id: UUID) async throws
        -> LibraryItem
    {
        try await coordinator.mutate { db, _, dependencies in
            try Self.requireWritableOwner(owner, in: db)
            guard let existing = try LibraryItemQueries.fetch(id, in: db) else {
                throw DocumentError.missingRecord
            }
            guard existing.kind == .document else { throw DocumentError.notPDF }
            guard existing.belongs(to: owner) else { throw DocumentError.ownerMismatch }
            let item = try draft.applying(
                to: existing,
                updatedAt: Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970))
            try LibraryItemQueries.update(item, in: db)
            return item
        }
    }

    static func requireWritableOwner(_ owner: LibraryItemOwner, in db: Database) throws {
        switch owner {
        case .job(let id): _ = try JobService.requireOpenJob(id, in: db)
        case .watch(let id):
            guard try WatchQueries.fetch(id, in: db) != nil else {
                throw DocumentError.unavailableOwner
            }
            try RecordAccess.requireWatch(id, in: db)
        case .caliber(let id):
            guard try CaliberQueries.fetch(id, in: db) != nil else {
                throw DocumentError.unavailableOwner
            }
            try RecordAccess.requireCaliber(id, in: db)
        }
    }

    func document(for assetID: UUID) async throws -> sending PDFDocument {
        let bytes = try await coordinator.documentBytes(for: assetID)
        return try await Self.decodeDocument(bytes)
    }

    @concurrent
    private static func decodeDocument(_ bytes: Data) async throws -> sending PDFDocument {
        try Task.checkCancellation()
        guard let document = PDFDocument(data: bytes) else { throw DocumentError.corruptPDF }
        guard !document.isEncrypted, !document.isLocked else { throw DocumentError.protectedPDF }
        guard document.pageCount > 0 else { throw DocumentError.corruptPDF }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw DocumentError.corruptPDF }
            for annotation in page.annotations where annotation.type == "Widget" {
                annotation.isReadOnly = true
            }
        }
        return document
    }

    func export(_ assetID: UUID, to destination: URL) async throws {
        try await coordinator.exportOriginal(assetID, to: destination)
    }

    @MainActor
    func openSource(_ item: LibraryItem) throws {
        guard item.kind == .document else { throw DocumentError.notPDF }
        guard let url = ReferenceDraft.parsedURL(item.sourceURL) else {
            throw ReferenceError.invalidURL
        }
        guard openBrowser(url) else { throw ReferenceError.browserUnavailable }
    }
}
