import SwiftUI

struct SettingsView: View {
    @Environment(LibraryState.self) private var library
    @Environment(BackupState.self) private var backup

    var body: some View {
        Form {
            Section("Library") {
                LabeledContent("Library folder") {
                    Text(library.coordinator.root.path)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("libraryFolder")
                }
            }
            Section("Library backup") {
                if let summary = backup.summary {
                    LabeledContent("Summary date") {
                        Text(summary.date, format: .dateTime.year().month().day().hour().minute())
                    }
                    LabeledContent("Saved items", value: "\(summary.itemCount)")
                    LabeledContent("Original files", value: "\(summary.originalCount)")
                    LabeledContent(
                        "Estimated size",
                        value: ByteCountFormatter.string(
                            fromByteCount: summary.estimatedByteCount, countStyle: .file))
                }
                if backup.isExporting {
                    ProgressView(backup.progressLabel)
                        .accessibilityIdentifier("backupProgress")
                    Text("Saves and imports wait until export finishes. Reading remains available.")
                        .foregroundStyle(.secondary)
                    Button("Cancel Export", action: backup.cancel)
                        .disabled(backup.progress == .publishing)
                } else {
                    Button("Export Library Backup…", action: backup.chooseDestination)
                        .disabled(backup.summary == nil || backup.isLoading || !isLibraryReady)
                        .accessibilityIdentifier("exportLibraryBackup")
                    Button("Refresh Summary", action: refreshSummary)
                        .disabled(backup.isLoading || !isLibraryReady)
                }
                if let lastExport = backup.lastExport {
                    LabeledContent("Last successful export") {
                        Text(lastExport, format: .dateTime.year().month().day().hour().minute())
                    }
                } else {
                    LabeledContent("Last successful export", value: "Never")
                }
                if let message = backup.message { Text(message).textSelection(.enabled) }
                if let error = backup.errorMessage {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                Text(
                    "Includes saved records and photo and PDF originals. Store a copy on another disk to protect against loss of this Mac. The export time does not confirm that a backup still exists."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Application", value: "Ure")
                LabeledContent("Version", value: version)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 620)
        .scenePadding()
        .task(loadSummary)
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Unknown"
    }

    private var isLibraryReady: Bool {
        if case .ready = library.phase { return true }
        return false
    }

    private func loadSummary() async {
        if isLibraryReady { await backup.refresh() }
    }

    private func refreshSummary() { Task { await backup.refresh() } }
}
