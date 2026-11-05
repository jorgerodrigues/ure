import SwiftUI

// The watches in order of name. Archived watches fold away in a section at the end of the list.
struct WatchListView: View {
    @Environment(WatchState.self) private var watches
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing

    var body: some View {
        @Bindable var watches = watches

        Group {
            if watches.isLoading {
                ProgressView("Loading watches…")
            } else if let error = watches.loadError {
                ContentUnavailableView {
                    Label("Watches could not load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry", action: retry)
                }
            } else if watches.watches.isEmpty {
                ContentUnavailableView {
                    Label("No watches", systemImage: "watch.analog")
                } description: {
                    Text("Add a watch with a name. Fill in its specifications when you know them.")
                } actions: {
                    Button("Add Watch", action: createWatch)
                }
            } else {
                List(selection: selection) {
                    ForEach(watches.filteredWatches) { watch in
                        WatchRow(watch: watch).tag(watch.id)
                    }
                    if !watches.archivedWatches.isEmpty {
                        ArchivedSectionHeader(
                            count: watches.archivedWatches.count,
                            isExpanded: $watches.showsArchived
                        )
                        .accessibilityIdentifier("archivedWatches")
                        if watches.showsArchived {
                            ForEach(watches.archivedWatches) { watch in
                                WatchRow(watch: watch).tag(watch.id)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("watchList")
                .overlay {
                    if watches.filteredWatches.isEmpty, watches.archivedWatches.isEmpty {
                        ContentUnavailableView.search(text: watches.searchText)
                    }
                }
            }
        }
        .navigationTitle("Watches")
        .navigationSubtitle(subtitle)
        .searchable(text: $watches.searchText, prompt: "Find a watch")
        .toolbar {
            Button("Add Watch", systemImage: "plus", action: createWatch)
                .labelStyle(.iconOnly)
                .help("Add Watch (⌘N)")
                .accessibilityIdentifier("addWatch")
                .disabled(editing.isSaving || watches.isLoading || watches.loadError != nil)
        }
        .disabled(editing.isSaving)
    }

    // Such as "12 watches · 3 archived".
    private var subtitle: String {
        let active = WatchWording.watches(watches.activeCount)
        if watches.archivedCount == 0 { return active }
        return "\(active) · \(watches.archivedCount) archived"
    }

    private var selection: Binding<UUID?> {
        Binding(get: selectedID, set: selectWatch)
    }

    private func selectedID() -> UUID? { watches.selectedID }

    // Clicking the Archived heading or an empty part of the list keeps the selected watch.
    private func selectWatch(_ id: UUID?) {
        guard let id, id != watches.selectedID else { return }
        editing.requestNavigation {
            jobs.close()
            watches.select(id)
        }
    }

    private func createWatch() {
        editing.requestNavigation {
            jobs.close()
            watches.createCommand()
        }
    }

    private func retry() {
        Task { await watches.observe() }
    }
}

// A watch in the list: its cover, its name, and its brand and year with its open job, such as
// "Omega · 1958 · In progress". An archived watch reads quieter and says when it was archived.
// Right-click archives or unarchives it.
private struct WatchRow: View {
    @Environment(WatchState.self) private var watches
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    @Environment(\.undoManager) private var undoManager
    let watch: WatchRecord

    var body: some View {
        HStack(spacing: UreLayout.rowSpacing) {
            PhotoThumbnailView(photoID: watch.coverPhotoID)
                .frame(width: UreLayout.rowThumbnailSize, height: UreLayout.rowThumbnailSize)
                .opacity(isArchived ? 0.7 : 1)
            VStack(alignment: .leading, spacing: UreLayout.textSpacing) {
                Text(watch.name)
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(isArchived ? .secondary : .primary)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(isArchived ? .tertiary : .secondary)
                }
            }
        }
        .contextMenu {
            Button(isArchived ? "Unarchive Watch" : "Archive Watch", action: toggleArchive)
                .disabled(editing.isSaving)
        }
        .accessibilityIdentifier("watchRow-\(watch.id.uuidString)")
    }

    private var isArchived: Bool { watch.archivedAt != nil }

    private var detail: String {
        var parts = [watch.brand]
        if let archivedAt = watch.archivedAt {
            parts.append("archived \(ArchivedDate.short(archivedAt))")
        } else {
            parts += [watch.approximateYear, jobs.openJob(for: watch.id)?.stage.rawValue]
        }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    private func toggleArchive() {
        editing.requestNavigation {
            jobs.close()
            watches.select(watch.id)
            watches.toggleArchiveCommand(undoManager: undoManager)
        }
    }
}

enum WatchWording {
    static func watches(_ count: Int) -> String {
        count == 1 ? "1 watch" : "\(count) watches"
    }

    static func jobs(_ count: Int) -> String {
        count == 1 ? "1 job" : "\(count) jobs"
    }
}
