import PDFKit
import SwiftUI

struct DocumentViewerView: View {
    @Environment(DocumentState.self) private var documents
    @State private var reader = DocumentReaderState()
    let assetID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if reader.isLoading {
                ProgressView("Opening PDF…")
            } else if let error = reader.error {
                ContentUnavailableView {
                    Label("PDF unavailable", systemImage: "doc.badge.ellipsis")
                } description: {
                    Text(error + " Retry, or use Export Original if the file is still available.")
                } actions: {
                    Button("Retry", action: retry)
                }
            } else {
                HStack {
                    Button("Previous Page", systemImage: "chevron.left", action: reader.previous)
                        .keyboardShortcut(.leftArrow, modifiers: []).disabled(!reader.canPrevious)
                    Text("Page \(reader.pageNumber) of \(reader.pageCount)")
                        .monospacedDigit().accessibilityIdentifier("documentPage")
                    Button("Next Page", systemImage: "chevron.right", action: reader.next)
                        .keyboardShortcut(.rightArrow, modifiers: []).disabled(!reader.canNext)
                    Spacer()
                    Button("Fit", action: reader.fit)
                    Button("Zoom Out", systemImage: "minus.magnifyingglass", action: reader.zoomOut)
                    Text(reader.scale.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                    Button("Zoom In", systemImage: "plus.magnifyingglass", action: reader.zoomIn)
                }.controlSize(.small).labelStyle(.iconOnly)
            }
            PDFReaderSurface(view: reader.pdfView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("PDF document")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(loadDocument)
        .onReceive(
            NotificationCenter.default.publisher(for: .PDFViewPageChanged, object: reader.pdfView),
            perform: refresh
        )
        .onReceive(
            NotificationCenter.default.publisher(for: .PDFViewScaleChanged, object: reader.pdfView),
            perform: refresh)
    }

    private func loadDocument() async { await reader.load(documents, assetID: assetID) }
    private func retry() { Task { await loadDocument() } }
    private func refresh(_ notification: Notification) { reader.refresh() }
}

private struct PDFReaderSurface: NSViewRepresentable {
    let view: PDFView
    func makeNSView(context: Context) -> PDFView { view }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}
