import PDFKit
import SwiftUI

struct DocumentViewerView: View {
    let source: ReferenceReader
    var usesKeyboardShortcuts = true
    var onLoadFailure: () -> Void = {}
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
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button(
                            "Previous Page", systemImage: "chevron.left", action: reader.previous
                        )
                        .keyboardShortcut(
                            usesKeyboardShortcuts
                                ? KeyboardShortcut(.leftArrow, modifiers: []) : nil
                        )
                        .disabled(!reader.canPrevious)
                        Text("Page \(reader.pageNumber) of \(reader.pageCount)")
                            .monospacedDigit().accessibilityIdentifier("documentPage")
                        Button("Next Page", systemImage: "chevron.right", action: reader.next)
                            .keyboardShortcut(
                                usesKeyboardShortcuts
                                    ? KeyboardShortcut(.rightArrow, modifiers: []) : nil
                            )
                            .disabled(!reader.canNext)
                        Spacer()
                    }
                    HStack {
                        Button("Fit", action: reader.fit)
                        Button(
                            "Zoom Out", systemImage: "minus.magnifyingglass", action: reader.zoomOut
                        )
                        Text(reader.scale.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit()
                        Button(
                            "Zoom In", systemImage: "plus.magnifyingglass", action: reader.zoomIn)
                        Spacer()
                    }
                }.controlSize(.small).labelStyle(.iconOnly)
            }
            PDFReaderSurface(view: reader.pdfView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("PDF document")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: assetID, loadDocument)
        .onReceive(
            NotificationCenter.default.publisher(for: .PDFViewPageChanged, object: reader.pdfView),
            perform: refresh
        )
        .onReceive(
            NotificationCenter.default.publisher(for: .PDFViewScaleChanged, object: reader.pdfView),
            perform: refresh)
    }

    private func loadDocument() async {
        await reader.load(source, assetID: assetID)
        if !Task.isCancelled, reader.error != nil { onLoadFailure() }
    }
    private func retry() { Task { await loadDocument() } }
    private func refresh(_ notification: Notification) { reader.refresh() }
}

private struct PDFReaderSurface: NSViewRepresentable {
    let view: PDFView
    func makeNSView(context: Context) -> PDFView { view }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}
