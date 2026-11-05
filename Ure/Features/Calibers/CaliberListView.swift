import SwiftUI

// The calibers by maker and name. Archived calibers fold away in a section at the end of the
// list.
struct CaliberListView: View {
    @Environment(CaliberState.self) private var calibers
    @Environment(WatchState.self) private var watches
    @Environment(WorkshopEditing.self) private var editing

    var body: some View {
        @Bindable var calibers = calibers

        Group {
            if calibers.isLoading {
                ProgressView("Loading calibers…")
            } else if let error = calibers.loadError {
                ContentUnavailableView {
                    Label("Calibers could not load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry", action: retry)
                }
            } else if calibers.calibers.isEmpty {
                ContentUnavailableView {
                    Label("No calibers", systemImage: "gearshape.2")
                } description: {
                    Text(
                        "Add a caliber with its exact designation. Leave unknown specifications empty."
                    )
                } actions: {
                    Button("Add Caliber", action: create)
                }
            } else {
                List(selection: selection) {
                    ForEach(calibers.filteredCalibers) { caliber in
                        CaliberRow(caliber: caliber, watchCount: watchCount(caliber.id))
                            .tag(caliber.id)
                    }
                    if !calibers.archivedCalibers.isEmpty {
                        ArchivedSectionHeader(
                            count: calibers.archivedCalibers.count,
                            isExpanded: $calibers.showsArchived
                        )
                        .accessibilityIdentifier("archivedCalibers")
                        if calibers.showsArchived {
                            ForEach(calibers.archivedCalibers) { caliber in
                                CaliberRow(caliber: caliber, watchCount: watchCount(caliber.id))
                                    .tag(caliber.id)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("caliberList")
                .overlay {
                    if calibers.filteredCalibers.isEmpty, calibers.archivedCalibers.isEmpty {
                        ContentUnavailableView.search(text: calibers.searchText)
                    }
                }
            }
        }
        .navigationTitle("Calibers")
        .navigationSubtitle(subtitle)
        .searchable(text: $calibers.searchText, prompt: "Find a caliber")
        .toolbar {
            Button("Add Caliber", systemImage: "plus", action: create)
                .labelStyle(.iconOnly)
                .help("Add Caliber (⌘N)")
                .accessibilityIdentifier("addCaliber")
                .disabled(editing.isSaving || calibers.isLoading || calibers.loadError != nil)
        }
        .disabled(editing.isSaving)
    }

    private var selection: Binding<UUID?> {
        Binding(get: selectedID, set: select)
    }

    private func selectedID() -> UUID? { calibers.selectedID }

    // Such as "7 calibers · 1 archived".
    private var subtitle: String {
        let count = calibers.activeCount
        let active = count == 1 ? "1 caliber" : "\(count) calibers"
        if calibers.archivedCount == 0 { return active }
        return "\(active) · \(calibers.archivedCount) archived"
    }

    private func watchCount(_ caliberID: UUID) -> Int {
        watches.watches.filter { $0.caliberID == caliberID }.count
    }

    // Clicking the Archived heading or an empty part of the list keeps the selected caliber.
    private func select(_ id: UUID?) {
        guard let id, id != calibers.selectedID else { return }
        editing.requestNavigation { calibers.select(id) }
    }

    private func create() { editing.requestNavigation(calibers.createCommand) }

    private func retry() {
        Task { await calibers.observe() }
    }
}

// A caliber in the list: its maker and name, then its winding and how many watches use it,
// such as "Automatic · 2 watches". An archived caliber reads quieter and says when it was
// archived. Right-click archives or unarchives it.
private struct CaliberRow: View {
    @Environment(CaliberState.self) private var calibers
    @Environment(WorkshopEditing.self) private var editing
    @Environment(\.undoManager) private var undoManager
    let caliber: CaliberRecord
    let watchCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: UreLayout.textSpacing) {
            Text(caliber.title)
                .font(.body)
                .fontWeight(.semibold)
                .foregroundStyle(isArchived ? .secondary : .primary)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(isArchived ? .tertiary : .secondary)
        }
        .contextMenu {
            Button(isArchived ? "Unarchive Caliber" : "Archive Caliber", action: toggleArchive)
                .disabled(editing.isSaving)
        }
    }

    private var isArchived: Bool { caliber.archivedAt != nil }

    private func toggleArchive() {
        editing.requestNavigation {
            calibers.select(caliber.id)
            calibers.toggleArchiveCommand(undoManager: undoManager)
        }
    }

    private var detail: String {
        if let archivedAt = caliber.archivedAt {
            return [caliber.winding?.rawValue, "archived \(ArchivedDate.short(archivedAt))"]
                .compactMap { $0 }.joined(separator: " · ")
        }
        let watches = watchCount == 0 ? "no watches yet" : WatchWording.watches(watchCount)
        guard let winding = caliber.winding else {
            return watches.prefix(1).uppercased() + watches.dropFirst()
        }
        return "\(winding.rawValue) · \(watches)"
    }
}
