import SwiftUI

struct LibraryRootView: View {
    @Environment(LibraryState.self) private var library

    var body: some View {
        Group {
            switch library.phase {
            case .loading:
                ProgressView("Opening library…")
            case .ready:
                WorkshopView()
            case .recovery(let reason):
                LibraryRecoveryView(reason: reason)
            }
        }
        .task(openLibrary)
    }

    private func openLibrary() async {
        if library.phase == .loading { await library.open() }
    }
}

private struct LibraryRecoveryView: View {
    @Environment(LibraryState.self) private var library
    let reason: String

    var body: some View {
        ContentUnavailableView {
            Label("Library needs recovery", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            VStack(spacing: 12) {
                Text("Ure could not open this library. The saved files have been kept.")
                Text(reason)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("libraryRecoveryReason")
                VStack(spacing: 4) {
                    Text("Library folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(library.coordinator.root.path)
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } actions: {
            Button("Retry", action: retry)
                .accessibilityIdentifier("retryLibrary")
        }
        .padding()
    }

    private func retry() {
        Task { await library.open() }
    }
}
