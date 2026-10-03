import Foundation
import PDFKit
import Testing

@testable import Ure

struct DocumentReaderStateTests {
    @Test
    func readerKeepsPageBoundsAndZoomClampedAndFitReturnsToAutomaticScale() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        let source = try DocumentFixture.source(in: fixture)
        let service = DocumentService(coordinator: coordinator)
        let record = try await service.importFiles([source], for: owner)[0].outcome.get()
        let reader = DocumentReaderState()
        reader.pdfView.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        await reader.load(ReferenceReader(coordinator: coordinator), assetID: record.asset.id)
        #expect(reader.error == nil && !reader.isLoading)
        #expect(reader.pageCount == 3 && reader.pageNumber == 1)
        #expect(!reader.canPrevious && reader.canNext)
        reader.previous()
        #expect(reader.pageNumber == 1)
        reader.next()
        #expect(reader.pageNumber == 2)
        reader.next()
        reader.next()
        #expect(reader.pageNumber == 3 && !reader.canNext)
        reader.previous()
        #expect(reader.pageNumber == 2)
        let beforeZoom = reader.scale
        reader.zoomIn()
        #expect(reader.scale > beforeZoom && !reader.pdfView.autoScales)
        for _ in 0..<50 { reader.zoomIn() }
        #expect(reader.scale == reader.pdfView.maxScaleFactor)
        for _ in 0..<50 { reader.zoomOut() }
        #expect(reader.scale == reader.pdfView.minScaleFactor)
        reader.fit()
        #expect(reader.pdfView.autoScales)
        try FileManager.default.removeItem(
            at: try await coordinator.originalURL(for: record.asset.id))
        await reader.load(ReferenceReader(coordinator: coordinator), assetID: record.asset.id)
        #expect(reader.error != nil && reader.pdfView.document == nil)
        #expect(reader.pageCount == 0 && !reader.canNext && !reader.canPrevious)
        try await coordinator.close()
    }
}
