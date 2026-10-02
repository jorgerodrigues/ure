import SwiftUI

struct WatchListView: View {
    @Environment(WatchState.self) private var watches

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
                    Button("Add Watch", action: watches.create)
                }
            } else {
                List(watches.filteredWatches, selection: selection) { watch in
                    WatchRow(watch: watch)
                        .tag(watch.id)
                }
                .accessibilityIdentifier("watchList")
                .overlay {
                    if watches.filteredWatches.isEmpty {
                        ContentUnavailableView.search(text: watches.searchText)
                    }
                }
            }
        }
        .navigationTitle("Watches")
        .searchable(text: $watches.searchText, prompt: "Find a watch")
        .toolbar {
            Button("Add Watch", systemImage: "plus", action: watches.create)
                .accessibilityIdentifier("addWatch")
                .disabled(watches.isSaving || watches.isLoading || watches.loadError != nil)
        }
        .disabled(watches.isSaving)
    }

    private var selection: Binding<UUID?> {
        Binding(get: selectedID, set: watches.select)
    }

    private func selectedID() -> UUID? { watches.selectedID }

    private func retry() {
        Task { await watches.observe() }
    }
}

private struct WatchRow: View {
    let watch: WatchRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(watch.name)
            if let brand = watch.brand {
                Text(brand)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("watchRow-\(watch.id.uuidString)")
    }
}
