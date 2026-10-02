import SwiftUI
import UniformTypeIdentifiers

struct PhotoSectionView: View {
    @Environment(PhotoState.self) private var photos
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    @State private var showsImporter = false
    @State private var pickerError: String?
    let owner: LibraryItemOwner

    var body: some View {
        @Bindable var photos = photos
        Section("\(owner.scope) photos") {
            if photos.isLoading {
                ProgressView("Loading photos…")
            } else if let error = photos.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                Button("Retry", action: retry)
            } else {
                Button("Import Photos", systemImage: "photo.badge.plus", action: chooseFiles)
                    .disabled(editing.isSaving || !photos.canWrite(owner, jobs: jobs))
                    .accessibilityIdentifier("importPhotos")
                Text("Choose or drop JPEG, PNG, or HEIC files here. Up to 200 files, 100 MB each.")
                    .font(.caption).foregroundStyle(.secondary)
                if !photos.canWrite(owner, jobs: jobs) {
                    Text("This job is closed. Reopen it to import or edit photos.")
                        .foregroundStyle(.secondary)
                }
                Picker("Stage", selection: $photos.stageFilter) {
                    Text("All stages").tag(Optional<PhotoStage>.none)
                    ForEach(PhotoStage.allCases, id: \.self) { stage in
                        Text(stage.rawValue).tag(Optional(stage))
                    }
                }
                if let error = pickerError { Label(error, systemImage: "exclamationmark.triangle") }
                if photos.importOwner == owner {
                    if photos.isImporting {
                        ProgressView("Importing photos…")
                        Button("Cancel Import", action: photos.cancelImport)
                    }
                    ForEach(photos.importResults) { result in PhotoImportResultView(result: result)
                    }
                }
                if photos.records(for: owner).isEmpty {
                    Text("No photos in this stage.").foregroundStyle(.secondary)
                } else {
                    ForEach(photos.records(for: owner)) { photo in
                        PhotoRow(photo: photo, owner: owner)
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showsImporter, allowedContentTypes: [.item],
            allowsMultipleSelection: true, onCompletion: pickedFiles
        )
        .dropDestination(for: URL.self, action: droppedFiles)
    }

    private func chooseFiles() {
        editing.requestNavigation { showsImporter = true }
    }
    private func pickedFiles(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let sources): beginImport(sources)
        case .failure(let error): pickerError = error.localizedDescription
        }
    }
    private func droppedFiles(_ sources: [URL], _ location: CGPoint) -> Bool {
        guard !sources.isEmpty, !editing.isSaving, photos.canWrite(owner, jobs: jobs) else {
            return false
        }
        beginImport(sources)
        return true
    }
    private func beginImport(_ sources: [URL]) {
        guard photos.canWrite(owner, jobs: jobs) else { return }
        pickerError = nil
        editing.requestNavigation { photos.importFiles(sources, for: owner) }
    }
    private func retry() { Task { await photos.observe() } }
}

private struct PhotoImportResultView: View {
    let result: FileImportResult<PhotoRecord>
    var body: some View {
        switch result.outcome {
        case .success:
            Label("\(result.source.lastPathComponent): Imported", systemImage: "checkmark.circle")
                .font(.caption)
        case .failure(let error):
            Label(
                "\(result.source.lastPathComponent): \(error.localizedDescription)",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption).foregroundStyle(.red)
        }
    }
}

private struct PhotoRow: View {
    @Environment(PhotoState.self) private var photos
    @Environment(WorkshopEditing.self) private var editing
    let photo: PhotoRecord
    let owner: LibraryItemOwner

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                PhotoThumbnailView(photoID: photo.id)
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(photo.item.title)
                    Text(photo.item.photoStage?.rawValue ?? "Unclassified")
                        .font(.caption).foregroundStyle(.secondary)
                    if let caption = photo.item.caption, !caption.isEmpty {
                        Text(caption).font(.caption).lineLimit(2)
                    }
                }
                Spacer()
            }
        }
        .disabled(editing.isSaving)
        .accessibilityIdentifier("photo-\(photo.id.uuidString)")
    }

    private func select() { editing.requestNavigation { photos.open(photo, for: owner) } }
}
