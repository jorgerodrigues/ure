import SwiftUI

struct WatchCaliberPicker: View {
    @Environment(WatchState.self) private var watches
    @Environment(CaliberState.self) private var calibers

    var body: some View {
        if calibers.isLoading {
            ProgressView("Loading calibers…")
        } else if let error = calibers.loadError {
            Label(error, systemImage: "exclamationmark.triangle")
            Button("Retry calibers", action: retry)
        } else {
            Picker("Caliber", selection: selection) {
                Text("Unknown").tag(Optional<UUID>.none)
                ForEach(
                    calibers.calibers.filter {
                        $0.archivedAt == nil || $0.id == watches.draft?.caliberID
                    }
                ) { caliber in
                    Text(caliber.label).tag(Optional(caliber.id))
                }
                if let id = watches.draft?.caliberID,
                    !calibers.calibers.contains(where: { $0.id == id })
                {
                    Text("Unavailable caliber").tag(Optional(id))
                }
            }
            .accessibilityIdentifier("watchCaliber")
        }
    }

    private var selection: Binding<UUID?> {
        Binding(get: currentCaliber, set: selectCaliber)
    }

    private func currentCaliber() -> UUID? { watches.draft?.caliberID }
    private func selectCaliber(_ id: UUID?) { watches.draft?.caliberID = id }

    private func retry() {
        Task { await calibers.observe() }
    }
}
