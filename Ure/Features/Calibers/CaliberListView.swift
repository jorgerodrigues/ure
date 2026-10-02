import SwiftUI

struct CaliberListView: View {
    @Environment(CaliberState.self) private var calibers

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
                    Button("Add Caliber", action: calibers.create)
                }
            } else {
                List(calibers.filteredCalibers, selection: selection) { caliber in
                    CaliberRow(caliber: caliber)
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
        .searchable(text: $calibers.searchText, prompt: "Find a caliber")
        .toolbar {
            Button("Add Caliber", systemImage: "plus", action: calibers.create)
                .accessibilityIdentifier("addCaliber")
                .disabled(calibers.isSaving || calibers.isLoading || calibers.loadError != nil)
        }
        .disabled(calibers.isSaving)
    }

    private var selection: Binding<UUID?> {
        Binding(get: selectedID, set: calibers.select)
    }

    private func selectedID() -> UUID? { calibers.selectedID }

    private func retry() {
        Task { await calibers.observe() }
    }
}

private struct CaliberRow: View {
    let caliber: CaliberRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caliber.label)
            if let manufacturer = caliber.manufacturer {
                Text(manufacturer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
