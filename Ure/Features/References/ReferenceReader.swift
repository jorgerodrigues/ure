import CoreGraphics
import AppKit
import Foundation
import PDFKit

nonisolated struct ReferenceReader: Sendable {
    private let coordinator: LibraryCoordinator
    var openBrowser: @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }

    init(coordinator: LibraryCoordinator) { self.coordinator = coordinator }

    func image(for assetID: UUID) async throws -> CGImage {
        try await PhotoService(coordinator: coordinator).image(for: assetID, thumbnail: false)
    }

    func document(for assetID: UUID) async throws -> sending PDFDocument {
        try await DocumentService(coordinator: coordinator).document(for: assetID)
    }

    func export(_ assetID: UUID, to destination: URL) async throws {
        try await coordinator.exportOriginal(assetID, to: destination)
    }

    @MainActor
    func openSource(_ item: LibraryItem) throws {
        guard item.kind == .link || item.kind == .document,
            let url = ReferenceDraft.parsedURL(item.sourceURL)
        else { throw ReferenceError.invalidURL }
        guard openBrowser(url) else { throw ReferenceError.browserUnavailable }
    }
}
