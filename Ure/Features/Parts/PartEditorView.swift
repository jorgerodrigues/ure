import SwiftUI

struct PartEditorView: View {
    @Environment(PartState.self) private var parts
    @Environment(JobState.self) private var jobs
    @FocusState private var descriptionFocused: Bool
    let jobID: UUID

    var body: some View {
        Form {
            Section("Part requirement") {
                TextField("Description", text: field(\.description))
                    .focused($descriptionFocused).accessibilityIdentifier("partDescription")
                PartFieldError(message: parts.fieldErrors[.description])
                TextField("Quantity", text: field(\.quantity))
                    .accessibilityIdentifier("partQuantity")
                PartFieldError(message: parts.fieldErrors[.quantity])
                Text("Use one requirement for each separately tracked unit or lot.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Manufacturer reference (optional)", text: field(\.manufacturerReference))
                    .accessibilityIdentifier("partManufacturerReference")
                LabeledContent(
                    "Status", value: parts.selectedPart?.record.status.rawValue ?? "Needed")
            }
            Section("Compatibility") {
                Picker("Assessment", selection: compatibility) {
                    ForEach(PartCompatibility.allCases) { value in Text(value.rawValue).tag(value) }
                }.accessibilityIdentifier("partCompatibility")
                TextField("Evidence or notes", text: field(\.compatibilityNote), axis: .vertical)
                    .accessibilityIdentifier("partCompatibilityNote")
                PartFieldError(message: parts.fieldErrors[.compatibilityNote])
                Text("Confirmed requires an evidence note.").font(.caption).foregroundStyle(
                    .secondary)
            }
            Section("Saved links") {
                ForEach(parts.draft?.links ?? []) { link in PartLinkEditorRow(link: link) }
                Button("Add link", systemImage: "plus", action: parts.addLink)
                    .accessibilityIdentifier("addPartLink")
                Text("A URL is enough. Links open only from the saved part's Open action.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !parts.canWrite(jobID, jobs: jobs) {
                Section { Text("Reopen a closed job to change its parts.") }
            }
            if let error = parts.saveError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        .accessibilityIdentifier("partSaveError")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(parts.isSaving || !parts.canWrite(jobID, jobs: jobs))
        .navigationTitle(parts.selectedID == nil ? "New Part" : "Edit Part")
        .toolbar {
            ToolbarItemGroup(placement: .confirmationAction) {
                if parts.isSaving { ProgressView().controlSize(.small) }
                Button("Cancel", action: parts.cancel).disabled(parts.isSaving)
                    .accessibilityIdentifier("cancelPart")
                Button("Save", action: parts.saveCommand).disabled(!parts.canSave(jobs: jobs))
                    .accessibilityIdentifier("savePart")
            }
        }
        .alert("Remove this saved link?", isPresented: removalPresented) {
            Button("Remove", role: .destructive, action: parts.confirmRemoveLink)
            Button("Cancel", role: .cancel, action: cancelRemoval)
        } message: {
            Text("The link will be removed when you save the part.")
        }
        .onAppear(perform: focusDescription)
    }

    private var compatibility: Binding<PartCompatibility> {
        Binding(get: currentCompatibility, set: selectCompatibility)
    }
    private func currentCompatibility() -> PartCompatibility {
        parts.draft?.compatibility ?? .unchecked
    }
    private func selectCompatibility(_ value: PartCompatibility) {
        parts.draft?.compatibility = value
    }
    private func focusDescription() { descriptionFocused = true }
    private var removalPresented: Binding<Bool> {
        Binding(get: { parts.linkToRemove != nil }, set: { if !$0 { parts.linkToRemove = nil } })
    }
    private func cancelRemoval() { parts.linkToRemove = nil }
    private func field(_ keyPath: WritableKeyPath<PartDraft, String>) -> Binding<String> {
        Binding(
            get: { parts.draft?[keyPath: keyPath] ?? "" },
            set: { parts.draft?[keyPath: keyPath] = $0 })
    }
}

private struct PartLinkEditorRow: View {
    @Environment(PartState.self) private var parts
    let link: PartLinkDraft

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("HTTP or HTTPS URL", text: url)
                    .accessibilityIdentifier("partLinkURL-\(link.id.uuidString)")
                Button("Remove link", systemImage: "minus.circle", action: remove)
                    .labelStyle(.iconOnly)
            }
            PartFieldError(message: parts.fieldErrors[.link(link.id)])
        }
    }
    private var url: Binding<String> { Binding(get: { link.url }, set: setURL) }
    private func setURL(_ value: String) { parts.setLinkURL(value, id: link.id) }
    private func remove() { parts.removeLink(link.id) }
}

private struct PartFieldError: View {
    let message: String?
    var body: some View {
        if let message {
            Text(message).font(.caption).foregroundStyle(.red)
                .accessibilityLabel("Field error: \(message)")
        }
    }
}
