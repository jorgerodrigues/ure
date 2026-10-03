import AppKit
import SwiftUI

struct PhotoDetailView: View {
    @Environment(PhotoState.self) private var photos
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    let owner: LibraryItemOwner

    var body: some View {
        Group {
            if photos.draft != nil {
                PhotoEditorView(owner: owner)
            } else if let photo = photos.selectedPhoto {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button("Previous", systemImage: "chevron.left", action: previous)
                            .keyboardShortcut(.leftArrow, modifiers: [])
                            .disabled(!photos.canMove(by: -1) || editing.isSaving)
                        Button("Next", systemImage: "chevron.right", action: next)
                            .keyboardShortcut(.rightArrow, modifiers: [])
                            .disabled(!photos.canMove(by: 1) || editing.isSaving)
                        Spacer()
                        Text(
                            "\(owner.scope) · \(photo.item.photoStage?.rawValue ?? "Unclassified")"
                        )
                        .foregroundStyle(.secondary)
                    }
                    PhotoViewerView(reader: photos.reader, assetID: photo.asset.id)
                        .id(photo.asset.id)
                    Text(photo.asset.originalFilename).font(.caption).textSelection(.enabled)
                    if let caption = photo.item.caption, !caption.isEmpty {
                        ScrollView { Text(caption).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 100).textSelection(.enabled)
                    }
                    if let error = photos.operationError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                    if !photos.canWrite(owner, jobs: jobs) {
                        Text("This job is closed. Reopen it to edit this photo.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .navigationTitle(photo.item.title)
                .toolbar {
                    Button("Edit Photo", action: edit)
                        .disabled(editing.isSaving || !photos.canWrite(owner, jobs: jobs))
                    Button("Export Original", action: exportOriginal).disabled(editing.isSaving)
                }
            } else {
                ContentUnavailableView("Photo unavailable", systemImage: "photo")
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back to \(owner.scope)", systemImage: "chevron.left", action: back)
                    .disabled(editing.isSaving)
            }
        }
    }

    private func previous() { photos.moveSelection(by: -1) }
    private func next() { photos.moveSelection(by: 1) }
    private func back() { editing.requestNavigation(photos.close) }
    private func edit() {
        guard photos.canWrite(owner, jobs: jobs) else { return }
        photos.edit()
    }
    private func exportOriginal() {
        guard let photo = photos.selectedPhoto else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = photo.asset.originalFilename
        panel.canCreateDirectories = true
        panel.title = "Export Original"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            photos.export(photo.asset.id, to: destination)
        }
    }
}
