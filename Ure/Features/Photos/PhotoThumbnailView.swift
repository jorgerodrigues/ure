import SwiftUI

struct PhotoThumbnailView: View {
    @Environment(PhotoState.self) private var photos
    @State private var image: CGImage?
    @State private var loadedAssetID: UUID?
    @State private var failed = false
    let photoID: UUID?

    private var assetID: UUID? { photos.thumbnail(for: photoID)?.asset.id }

    var body: some View {
        Group {
            if let image, loadedAssetID == assetID {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                Image(systemName: failed ? "photo.badge.exclamationmark" : "photo")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        failed
                            ? "Thumbnail unavailable. Open the photo to view its original."
                            : "Photo")
            }
        }
        .task(id: assetID, loadThumbnail)
    }

    private func loadThumbnail() async {
        image = nil
        failed = false
        guard let assetID else { return }
        do {
            let loaded = try await photos.image(for: assetID, thumbnail: true)
            guard !Task.isCancelled else { return }
            image = loaded
            loadedAssetID = assetID
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}
