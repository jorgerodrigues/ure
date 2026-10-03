import SwiftUI

struct PartSectionView: View {
    @Environment(PartState.self) private var parts
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    let jobID: UUID

    var body: some View {
        Section("Parts") {
            if parts.isLoading {
                ProgressView("Loading parts…")
            } else if let error = parts.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                Button("Retry", action: retry)
            } else {
                Button("Add Part", systemImage: "plus", action: create)
                    .disabled(editing.isSaving || !parts.canWrite(jobID, jobs: jobs))
                    .accessibilityIdentifier("addPart")
                if parts.records(for: jobID).isEmpty {
                    Text("No parts required.").foregroundStyle(.secondary)
                } else {
                    ForEach(parts.records(for: jobID)) { part in PartRow(part: part) }
                }
            }
        }
    }
    private func create() { editing.requestNavigation { parts.create(for: jobID, jobs: jobs) } }
    private func retry() { Task { await parts.observe() } }
}

private struct PartRow: View {
    @Environment(PartState.self) private var parts
    @Environment(WorkshopEditing.self) private var editing
    let part: PartRequirement

    var body: some View {
        Button(action: open) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(part.record.description)
                    Text("Quantity \(part.record.quantity) · \(part.record.compatibility.rawValue)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(part.record.status.rawValue).foregroundStyle(.secondary)
            }
        }
        .disabled(editing.isSaving)
        .accessibilityIdentifier("part-\(part.id.uuidString)")
    }
    private func open() { editing.requestNavigation { parts.open(part, for: part.record.jobID) } }
}
