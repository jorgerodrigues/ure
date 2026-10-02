import Observation
import PDFKit

@Observable
final class DocumentReaderState {
    @ObservationIgnored let pdfView = PDFView()
    private(set) var isLoading = true
    private(set) var error: String?
    private(set) var pageNumber = 0
    private(set) var pageCount = 0
    private(set) var scale = 1.0

    init() {
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.isInMarkupMode = false
        pdfView.minScaleFactor = 0.1
        pdfView.maxScaleFactor = 8
        pdfView.autoScales = true
    }

    func load(_ documents: DocumentState, assetID: UUID) async {
        isLoading = true
        error = nil
        do {
            let document = try await documents.document(for: assetID)
            try Task.checkCancellation()
            pdfView.document = document
            pdfView.autoScales = true
            refresh()
            isLoading = false
        } catch {
            if Task.isCancelled { return }
            pdfView.document = nil
            refresh()
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    func refresh() {
        pageCount = pdfView.document?.pageCount ?? 0
        pageNumber = 0
        if let document = pdfView.document, let page = pdfView.currentPage {
            pageNumber = document.index(for: page) + 1
        }
        scale = pdfView.scaleFactor
    }

    var canPrevious: Bool { pageNumber > 1 }
    var canNext: Bool { pageNumber > 0 && pageNumber < pageCount }
    func previous() { if canPrevious { pdfView.goToPreviousPage(nil); refresh() } }
    func next() { if canNext { pdfView.goToNextPage(nil); refresh() } }
    func fit() { pdfView.autoScales = true; refresh() }
    func zoomIn() { zoom(by: 1.25) }
    func zoomOut() { zoom(by: 0.8) }

    private func zoom(by factor: Double) {
        let next = pdfView.scaleFactor * factor
        pdfView.autoScales = false
        pdfView.scaleFactor = min(pdfView.maxScaleFactor, max(pdfView.minScaleFactor, next))
        refresh()
    }
}
