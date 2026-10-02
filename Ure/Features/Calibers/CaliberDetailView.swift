import SwiftUI

struct CaliberDetailView: View {
    @Environment(CaliberState.self) private var calibers
    @Environment(WatchState.self) private var watches
    @Environment(NoteState.self) private var notes
    @Environment(DocumentState.self) private var documents
    @Environment(PhotoState.self) private var photos
    @Environment(ReferenceState.self) private var references

    var body: some View {
        if calibers.draft != nil {
            CaliberEditorView()
        } else if let caliber = calibers.selectedCaliber,
            documents.isPresenting(for: .caliber(caliber.id))
        {
            DocumentDetailView(owner: .caliber(caliber.id))
        } else if let caliber = calibers.selectedCaliber,
            photos.isPresenting(for: .caliber(caliber.id))
        {
            PhotoDetailView(owner: .caliber(caliber.id))
        } else if let caliber = calibers.selectedCaliber,
            references.isPresenting(for: .caliber(caliber.id))
        {
            ReferenceDetailView(owner: .caliber(caliber.id))
        } else if let caliber = calibers.selectedCaliber,
            notes.isPresenting(for: .caliber(caliber.id))
        {
            NoteDetailView(owner: .caliber(caliber.id))
        } else if let caliber = calibers.selectedCaliber {
            Form {
                Section("Shared specifications") {
                    CaliberSpecificationsView(caliber: caliber)
                }
                NoteSectionView(owner: .caliber(caliber.id))
                PhotoSectionView(owner: .caliber(caliber.id))
                ReferenceSectionView(owner: .caliber(caliber.id))
                Section("Linked watches") {
                    if watches.isLoading {
                        ProgressView("Loading watches…")
                    } else if let error = watches.loadError {
                        Label(error, systemImage: "exclamationmark.triangle")
                        Button("Retry", action: retryWatches)
                    } else if linkedWatches.isEmpty {
                        Text("No watches refer to this caliber.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(linkedWatches) { watch in
                            CaliberWatchLink(watch: watch)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .textSelection(.enabled)
            .navigationTitle(caliber.label)
            .toolbar {
                Button("Edit", action: calibers.edit)
                    .accessibilityIdentifier("editCaliber")
            }
        } else {
            ContentUnavailableView(
                "Select a caliber", systemImage: "gearshape.2",
                description: Text("Choose a caliber or add a new one.")
            )
        }
    }

    private var linkedWatches: [WatchRecord] {
        watches.watches.filter { $0.caliberID == calibers.selectedID }
    }

    private func retryWatches() {
        Task { await watches.observe() }
    }
}

private struct CaliberWatchLink: View {
    @Environment(WatchState.self) private var watches
    @Environment(WorkshopNavigation.self) private var navigation
    @Environment(WorkshopEditing.self) private var editing
    let watch: WatchRecord

    var body: some View {
        Button(watch.name, action: openWatch)
            .accessibilityIdentifier("caliberWatch-\(watch.id)")
    }

    private func openWatch() {
        editing.requestNavigation {
            editing.jobs.close()
            watches.searchText = ""
            watches.select(watch.id)
            navigation.selection = .watches
        }
    }
}
