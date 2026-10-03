import SwiftUI

struct RestoreSectionView: View {
    @Environment(RestoreState.self) private var restore

    var body: some View {
        @Bindable var restore = restore
        Section("Restore library") {
            Text(
                "Restore replaces all saved records and originals. Changes made after the backup date will be lost. Records are not merged."
            )
            .foregroundStyle(.secondary)
            if restore.isStaging {
                ProgressView("Checking and preparing backup…")
                Button("Cancel Restore", action: restore.cancel)
            } else if restore.isActivating {
                ProgressView("Saving recovery copy and restoring library…")
            } else if let staged = restore.staged {
                LabeledContent("Backup date") {
                    Text(
                        staged.summary.exportedAt,
                        format: .dateTime.year().month().day().hour().minute())
                }
                LabeledContent("Backup app version", value: staged.summary.applicationVersion)
                ForEach(staged.summary.counts.keys.sorted(), id: \.self) { table in
                    RestoreCountRow(table: table, count: staged.summary.counts[table] ?? 0)
                }
                LabeledContent("Original files", value: "\(staged.summary.originalCount)")
                LabeledContent(
                    "Backup size",
                    value: ByteCountFormatter.string(
                        fromByteCount: staged.summary.byteCount, countStyle: .file))
                if !staged.summary.appliedMigrations.isEmpty {
                    Text("The prepared copy was upgraded to the current library format.")
                        .foregroundStyle(.secondary)
                }
                Text(
                    "A complete recovery copy will be saved before replacement. Open records and reference windows will reset."
                )
                .foregroundStyle(.secondary)
                Button("Replace Library…", role: .destructive, action: restore.requestConfirmation)
                    .disabled(!restore.canRestore)
                    .accessibilityIdentifier("replaceLibrary")
                Button("Cancel Restore", action: restore.cancel)
            } else {
                Button("Restore Library Backup…", action: restore.chooseBackup)
                    .disabled(!restore.canRestore)
                    .accessibilityIdentifier("restoreLibraryBackup")
            }
            if restore.session.editing.hasUnsavedChanges || restore.session.editing.isSaving {
                Text(
                    "Save or cancel all drafts and wait for pending saves and imports before restoring."
                )
                .foregroundStyle(.secondary)
            }
            if let message = restore.message { Text(message).textSelection(.enabled) }
            if let error = restore.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if let directory = restore.recoveryDirectory {
                Text(directory.path).font(.callout).textSelection(.enabled)
                Button("Show Recovery Copy in Finder", action: restore.revealRecovery)
            }
        }
        .alert("Replace the current library?", isPresented: $restore.showsConfirmation) {
            Button("Replace Library", role: .destructive, action: restore.confirm)
            Button("Cancel", role: .cancel, action: restore.cancelConfirmation)
        } message: {
            Text(
                "All current records and originals will be replaced by the reviewed backup. Changes after its date will be lost. Ure will first save a recovery copy of the current library."
            )
        }
    }
}

private struct RestoreCountRow: View {
    let table: String
    let count: Int

    var body: some View {
        LabeledContent(label, value: "\(count)")
    }

    private var label: String {
        switch table {
        case "watch": "Watches"
        case "caliber": "Calibers"
        case "job": "Jobs"
        case "jobTask": "Tasks"
        case "partRequirement": "Parts"
        case "partLink": "Supplier links"
        case "taskPart": "Task part links"
        case "note": "Notes"
        case "libraryItem": "Photos, PDFs and references"
        case "fileAsset": "Original file records"
        case "activityEvent": "History entries"
        case "libraryMetadata": "Library"
        default: "Saved records"
        }
    }
}
