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
            }
            PartProcurementEditorSection()
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
                PartFieldError(message: parts.fieldErrors[.selectedLink])
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
                Button("Save", action: parts.saveCommand).buttonStyle(.borderedProminent).disabled(
                    !parts.canSave(jobs: jobs)
                )
                .accessibilityIdentifier("savePart")
            }
        }
        .alert("Remove this saved link?", isPresented: removalPresented) {
            Button("Remove", role: .destructive, action: parts.confirmRemoveLink)
            Button("Cancel", role: .cancel, action: cancelRemoval)
        } message: {
            Text(
                "The link and its supplier details will be removed when you save. If selected, the supplier choice will also be cleared."
            )
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

private struct PartProcurementEditorSection: View {
    @Environment(PartState.self) private var parts

    var body: some View {
        Section("Procurement") {
            Picker("Status", selection: status) {
                ForEach(statuses) { value in Text(value.rawValue).tag(value) }
            }.accessibilityIdentifier("partStatus")
            PartFieldError(message: parts.fieldErrors[.status])
            if parts.draft?.status == .ordered {
                TextField("Order reference (optional)", text: field(\.orderReference))
                    .accessibilityIdentifier("partOrderReference")
                Text("Ordering saves a copy of the selected supplier option with this whole lot.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if parts.draft?.needsReason == true {
                TextField(
                    "Correction or cancellation reason", text: field(\.statusReason),
                    axis: .vertical
                )
                .accessibilityIdentifier("partStatusReason")
                PartFieldError(message: parts.fieldErrors[.statusReason])
            }
            if parts.draft?.needsOnHandConfirmation == true {
                Toggle("The complete unit or lot is on hand", isOn: onHand)
                    .toggleStyle(.checkbox).accessibilityIdentifier("partOnHand")
                Text("Save will record arrival and installation together.")
                    .font(.caption).foregroundStyle(.secondary)
                PartFieldError(message: parts.fieldErrors[.onHand])
            }
            Text(
                "Arrived means on hand. Installed means fitted. Save records the current date and time."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statuses: [PartStatus] {
        if parts.selectedID == nil { return [.needed, .arrived] }
        return PartStatus.allCases
    }
    private var status: Binding<PartStatus> { Binding(get: currentStatus, set: setStatus) }
    private func currentStatus() -> PartStatus { parts.draft?.status ?? .needed }
    private func setStatus(_ value: PartStatus) { parts.setStatus(value) }
    private var onHand: Binding<Bool> { Binding(get: currentOnHand, set: setOnHand) }
    private func currentOnHand() -> Bool { parts.draft?.confirmsOnHand ?? false }
    private func setOnHand(_ value: Bool) { parts.confirmOnHand(value) }
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
            Toggle("Selected supplier option", isOn: selected)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("selectPartLink-\(link.id.uuidString)")
            TextField("Supplier name (optional)", text: field(\.supplierName))
                .accessibilityIdentifier("partLinkSupplier-\(link.id.uuidString)")
            TextField("Listing title (optional)", text: field(\.title))
                .accessibilityIdentifier("partLinkTitle-\(link.id.uuidString)")
            TextField("Supplier stock code (optional)", text: field(\.supplierStockCode))
                .accessibilityIdentifier("partLinkStockCode-\(link.id.uuidString)")
            HStack {
                TextField("HTTP or HTTPS URL", text: url)
                    .accessibilityIdentifier("partLinkURL-\(link.id.uuidString)")
                Button("Remove link", systemImage: "minus.circle", action: remove)
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Remove link \(link.url)")
                    .accessibilityIdentifier("removePartLink-\(link.id.uuidString)")
            }
            PartFieldError(message: parts.fieldErrors[.link(link.id)])
            TextField("Price (optional)", text: field(\.price))
                .accessibilityIdentifier("partLinkPrice-\(link.id.uuidString)")
            PartFieldError(message: parts.fieldErrors[.price(link.id)])
            TextField("Currency code (optional)", text: field(\.currency))
                .accessibilityIdentifier("partLinkCurrency-\(link.id.uuidString)")
            PartFieldError(message: parts.fieldErrors[.currency(link.id)])
            Text("Use a decimal point, for example 12.3400. A price needs a currency, such as DKK.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Notes (optional)", text: field(\.notes), axis: .vertical)
                .accessibilityIdentifier("partLinkNotes-\(link.id.uuidString)")
        }
    }
    private var selected: Binding<Bool> { Binding(get: isSelected, set: select) }
    private func isSelected() -> Bool { parts.draft?.selectedLinkID == link.id }
    private func select(_ value: Bool) {
        if value { parts.selectLink(link.id) } else { parts.selectLink(nil) }
    }
    private func field(_ keyPath: WritableKeyPath<PartLinkDraft, String>) -> Binding<String> {
        Binding(
            get: { link[keyPath: keyPath] },
            set: { parts.setLinkField($0, id: link.id, keyPath: keyPath) })
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
