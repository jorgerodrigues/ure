import SwiftUI

struct WatchCaliberView: View {
    @Environment(CaliberState.self) private var calibers
    let caliberID: UUID?

    var body: some View {
        if let caliberID {
            if let caliber = calibers.calibers.first(where: { $0.id == caliberID }) {
                CaliberSpecificationsView(caliber: caliber)
            } else if calibers.isLoading {
                ProgressView("Loading caliber…")
            } else if let error = calibers.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                Button("Retry", action: retry)
            } else {
                Text("This caliber is unavailable.")
                    .foregroundStyle(.secondary)
            }
        } else {
            LabeledContent("Caliber", value: "Unknown")
        }
    }

    private func retry() {
        Task { await calibers.observe() }
    }
}
