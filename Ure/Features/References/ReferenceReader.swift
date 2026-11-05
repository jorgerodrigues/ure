import AppKit
import CoreGraphics
import Foundation
import PDFKit

nonisolated struct ReferenceReader: Sendable {
    private let service: MaterialService

    init(coordinator: LibraryCoordinator) { service = MaterialService(coordinator: coordinator) }

    func image(for assetID: UUID) async throws -> CGImage {
        try await service.image(for: assetID, thumbnail: false)
    }

    func document(for assetID: UUID) async throws -> sending PDFDocument {
        try await service.document(for: assetID)
    }

    func export(_ assetID: UUID, to destination: URL) async throws {
        try await service.export(assetID, to: destination)
    }

    @MainActor
    func openLink(_ item: LibraryItem) throws {
        try service.openLink(item)
    }
}
