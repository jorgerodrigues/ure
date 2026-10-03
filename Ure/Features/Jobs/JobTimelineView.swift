import SwiftUI

struct JobTimelineView: View {
    @Environment(LibraryState.self) private var library
    @Environment(WorkshopEditing.self) private var editing
    @State private var timeline = JobTimelineState()
    @State private var reloadCount = 0
    let jobID: UUID
    let onClose: () -> Void

    var body: some View {
        Form {
            Section {
                Text(
                    "Saved changes and job notes, newest first. This is a repair history, not a complete audit log."
                )
                .foregroundStyle(.secondary)
            }
            Section("Activity") {
                if timeline.isLoading {
                    ProgressView("Loading activity…")
                } else if let error = timeline.loadError {
                    Label(error, systemImage: "exclamationmark.triangle")
                    Button("Retry", action: retry)
                } else if timeline.entries.isEmpty {
                    Text("No activity or job notes yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(timeline.entries) { entry in
                        JobTimelineRow(
                            entry: entry, timeline: timeline, jobID: jobID, onOpen: onClose)
                    }
                }
                if let error = timeline.navigationError {
                    Label(error, systemImage: "exclamationmark.triangle")
                }
            }
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
        .navigationTitle("Job Activity")
        .task(id: "\(jobID.uuidString)-\(reloadCount)", observe)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back to Job", systemImage: "chevron.left", action: back)
                    .disabled(editing.isSaving).accessibilityIdentifier("backFromActivity")
            }
        }
    }

    private func observe() async {
        await timeline.observe(jobID: jobID, coordinator: library.coordinator)
    }
    private func retry() { reloadCount += 1 }
    private func back() { editing.requestNavigation(onClose) }
}

private struct JobTimelineRow: View {
    @Environment(WorkshopEditing.self) private var editing
    let entry: JobTimelineEntry
    let timeline: JobTimelineState
    let jobID: UUID
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.occurredAt, format: .dateTime).font(.caption).foregroundStyle(.secondary)
            Text(entry.title).font(.headline)
            if let subject = entry.subject { Text(subject) }
            Text(entry.summary)
            if let body = entry.body {
                Text(body).fixedSize(horizontal: false, vertical: true)
            }
            if !entry.prior.isEmpty {
                DisclosureGroup("Previous and new values") {
                    JobTimelineValues(title: "Previous", fields: entry.prior)
                    JobTimelineValues(title: "New", fields: entry.next)
                }
            }
            if let source = entry.source {
                Button(source.label, action: open).disabled(editing.isSaving)
                    .accessibilityLabel("\(source.label): \(entry.subject ?? entry.title)")
            } else if let message = entry.unavailableSource {
                Text(message).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func open() {
        timeline.openSource(entry, jobID: jobID, editing: editing, onOpen: onOpen)
    }
}

private struct JobTimelineValues: View {
    let title: String
    let fields: [JobTimelineField]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.label).font(.caption).foregroundStyle(.secondary)
                    if let date = field.date {
                        Text(date, format: .dateTime)
                    } else {
                        Text(field.text ?? "Not recorded")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
    }
}
