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
                    Section("Saved links") {
                        if part.links.isEmpty {
                            Text("No links saved.").foregroundStyle(.secondary)
                        } else if part.selectedLink == nil {
                            Text("No supplier option selected.").foregroundStyle(.secondary)
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
                    Button("Edit Part", action: edit)
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
    }
    private func edit() { parts.edit(jobs: jobs) }
    private func back() { editing.requestNavigation(parts.close) }
    private func retry() { Task { await parts.observe() } }
}

private struct PartLinkRow: View {
    @Environment(PartState.self) private var parts
    let link: PartLink
    var body: some View {
        VStack(alignment: .leading) {
            if link.isSelected {
                Label("Selected supplier option", systemImage: "checkmark.circle")
                    .accessibilityIdentifier("selectedPartLink-\(link.id.uuidString)")
            }
            if let supplier = link.supplierName { LabeledContent("Supplier", value: supplier) }
            if let title = link.title { LabeledContent("Listing", value: title) }
            if let code = link.supplierStockCode {
                LabeledContent("Supplier stock code", value: code)
            }
            if let price = link.price, let currency = link.currency {
                LabeledContent("Price", value: "\(price) \(currency)")
            } else if let currency = link.currency {
                LabeledContent("Currency", value: currency)
            }
            HStack {
                Text(link.url).frame(maxWidth: .infinity, alignment: .leading)
                Button("Open", action: open)
                    .accessibilityLabel("Open \(link.url) in browser")
                    .accessibilityIdentifier("openPartLink-\(link.id.uuidString)")
            }
            if let notes = link.notes { LabeledContent("Notes", value: notes) }
        }
    }
    private func open() { parts.openLink(link) }
}
