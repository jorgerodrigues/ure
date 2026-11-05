import SwiftUI

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
                List(calibers.filteredCalibers, selection: selection) { caliber in
                    CaliberRow(caliber: caliber, watchCount: watchCount(caliber.id))
                        .tag(caliber.id)
                }
                .accessibilityIdentifier("caliberList")
                .overlay {
                    if calibers.filteredCalibers.isEmpty {
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

    private var subtitle: String {
        let count = calibers.filteredCalibers.count
        return count == 1 ? "1 caliber" : "\(count) calibers"
    }

    private func watchCount(_ caliberID: UUID) -> Int {
        watches.watches.filter { $0.caliberID == caliberID }.count
    }

    private func select(_ id: UUID?) {
        guard id != calibers.selectedID else { return }
        editing.requestNavigation { calibers.select(id) }
    }

    private func create() { editing.requestNavigation(calibers.createCommand) }

    private func retry() {
        Task { await calibers.observe() }
    }
}

// A caliber in the list: its maker and name, then its winding and how many watches use it,
// such as "Automatic · 2 watches".
private struct CaliberRow: View {
    let caliber: CaliberRecord
    let watchCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: UreLayout.textSpacing) {
            Text(caliber.title).font(.body).fontWeight(.semibold)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        let watches = watchCount == 0 ? "no watches yet" : CaliberWording.watches(watchCount)
        guard let winding = caliber.winding else {
            return watches.prefix(1).uppercased() + watches.dropFirst()
        }
        return "\(winding.rawValue) · \(watches)"
    }
}
