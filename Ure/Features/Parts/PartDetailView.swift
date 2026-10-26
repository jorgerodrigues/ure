import SwiftUI

struct PartDetailView: View {
    @Environment(PartState.self) private var parts
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    let jobID: UUID

    var body: some View {
        Group {
            if parts.draft != nil {
                PartEditorView(jobID: jobID)
            } else if let error = parts.loadError {
                ContentUnavailableView {
                    Label("Parts unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry", action: retry)
                }
            } else if let part = parts.selectedPart {
                Form {
                    Section("Part requirement") {
                        LabeledContent("Description", value: part.record.description)
                        LabeledContent("Quantity", value: String(part.record.quantity))
                        LabeledContent(
                            "Manufacturer reference",
                            value: part.record.manufacturerReference ?? "Unknown")
                        LabeledContent("Status", value: part.record.status.rawValue)
                        LabeledContent("Compatibility", value: part.record.compatibility.rawValue)
                        if let note = part.record.compatibilityNote {
                            LabeledContent("Evidence or notes", value: note)
                        }
                    }
                    PartProcurementSection(record: part.record)
                    Section("Saved links") {
                        if part.links.isEmpty {
                            Text("No links saved.").foregroundStyle(.secondary)
                        }
                        ForEach(part.links) { link in PartLinkRow(link: link) }
                        if let error = parts.openError {
                            Label(error, systemImage: "exclamationmark.triangle")
                        }
                    }
                    if !parts.canWrite(jobID, jobs: jobs) {
                        Section { Text("Reopen a closed job to change its parts.") }
                    }
                }
                .formStyle(.grouped).textSelection(.enabled)
                .navigationTitle(part.record.description)
                .toolbar {
                    Button("Edit Part", systemImage: "pencil", action: edit)
                        .labelStyle(.iconOnly)
                        .help("Edit Part (⌥⌘E)")
                        .disabled(editing.isSaving || !parts.canWrite(jobID, jobs: jobs))
                        .accessibilityIdentifier("editPart")
                }
            } else {
                ContentUnavailableView("Part unavailable", systemImage: "gearshape")
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back to Job", systemImage: "chevron.left", action: back)
                    .disabled(editing.isSaving).accessibilityIdentifier("backFromPart")
            }
        }
        .focusedSceneValue(\.recordMenuActions, menuActions)
        .focusedSceneValue(\.recordBackAction, backAction)
    }
    private var menuActions: RecordMenuActions {
        guard parts.draft == nil, parts.loadError == nil, parts.selectedPart != nil,
            !editing.isSaving, parts.canWrite(jobID, jobs: jobs)
        else { return RecordMenuActions() }
        return RecordMenuActions(edit: edit)
    }
    private func edit() { parts.edit(jobs: jobs) }
    private var backAction: (() -> Void)? {
        guard !editing.isSaving else { return nil }
        return back
    }

    private func back() { editing.requestNavigation(parts.close) }
    private func retry() { Task { await parts.observe() } }
}

struct PartProcurementSection: View {
    let record: PartRecord

    var body: some View {
        Section("Procurement") {
            if let date = record.orderedAt { LabeledContent("Ordered", value: date.formatted()) }
            if let date = record.arrivedAt { LabeledContent("Arrived", value: date.formatted()) }
            if let date = record.installedAt {
                LabeledContent("Installed", value: date.formatted())
            }
            if let date = record.cancelledAt {
                LabeledContent("Cancelled", value: date.formatted())
            }
            if let reason = record.statusReason { LabeledContent("Reason", value: reason) }
            if let reference = record.orderReference {
                LabeledContent("Order reference", value: reference)
            }
        }
    }
}

private struct PartLinkRow: View {
    @Environment(PartState.self) private var parts
    let link: PartLink
    var body: some View {
        HStack {
            Text(link.url).frame(maxWidth: .infinity, alignment: .leading)
            Button("Open", action: open)
                .accessibilityLabel("Open \(link.url) in browser")
                .accessibilityIdentifier("openPartLink-\(link.id.uuidString)")
        }
    }
    private func open() { parts.openLink(link) }
}
