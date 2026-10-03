import SwiftUI

struct PhotoViewerView: View {
    let reader: ReferenceReader
    var usesKeyboardShortcuts = true
    var onLoadFailure: () -> Void = {}
    @State private var image: CGImage?
    @State private var loadError: String?
    @State private var retryID = UUID()
    @State private var zoom = PhotoZoomRequest()
    let assetID: UUID

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Fit", action: fit)
                    .keyboardShortcut(usesKeyboardShortcuts ? KeyboardShortcut("0") : nil)
                Button("Zoom Out", systemImage: "minus.magnifyingglass", action: zoomOut)
                    .keyboardShortcut(usesKeyboardShortcuts ? KeyboardShortcut("-") : nil)
                Button("Zoom In", systemImage: "plus.magnifyingglass", action: zoomIn)
                    .keyboardShortcut(usesKeyboardShortcuts ? KeyboardShortcut("+") : nil)
                Spacer()
            }
            .labelStyle(.iconOnly)
            .disabled(image == nil)
            Text("Drag to pan. Pinch or use the zoom controls.")
                .font(.caption).foregroundStyle(.secondary)
            if let image {
                PhotoViewport(image: image, assetID: assetID, request: zoom)
                    .accessibilityLabel("Photo viewer")
                    .frame(minHeight: 260)
            } else if let error = loadError {
                ContentUnavailableView {
                    Label("Photo could not load", systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry", action: retry)
                }
                .frame(maxHeight: .infinity)
            } else {
                ProgressView("Loading original…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: PhotoImageRequest(assetID: assetID, retryID: retryID), loadImage)
    }

    private func loadImage() async {
        image = nil
        loadError = nil
        zoom = PhotoZoomRequest()
        do {
            let loaded = try await reader.image(for: assetID)
            guard !Task.isCancelled else { return }
            image = loaded
        } catch {
            if !Task.isCancelled {
                loadError = error.localizedDescription
                onLoadFailure()
            }
        }
    }
    private func retry() { retryID = UUID() }
    private func fit() { zoom = PhotoZoomRequest(action: .fit) }
    private func zoomOut() { zoom = PhotoZoomRequest(action: .out) }
    private func zoomIn() { zoom = PhotoZoomRequest(action: .in) }
}

private struct PhotoImageRequest: Hashable {
    let assetID: UUID
    let retryID: UUID
}
