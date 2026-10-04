import SwiftUI

struct CaliberEditorView: View {
    @Environment(CaliberState.self) private var calibers
    @FocusState private var focusedField: CaliberField?

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Designation", text: field(\.designation))
                    .focused($focusedField, equals: .designation)
                    .accessibilityIdentifier("caliberDesignation")
                CaliberFieldError(message: calibers.fieldErrors[.designation])
                TextField("Manufacturer", text: field(\.manufacturer))
                    .accessibilityIdentifier("caliberManufacturer")
                TextField("Variant", text: field(\.variant))
                    .accessibilityIdentifier("caliberVariant")
            }
            Section("Specifications") {
                Picker("Movement type", selection: movementType) {
                    ForEach(MovementType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .accessibilityIdentifier("caliberMovementType")
                TextField("Beat rate (vph)", text: field(\.beatRate))
                    .accessibilityIdentifier("caliberBeatRate")
                CaliberFieldError(message: calibers.fieldErrors[.beatRate])
                TextField("Jewel count", text: field(\.jewelCount))
                    .accessibilityIdentifier("caliberJewelCount")
                CaliberFieldError(message: calibers.fieldErrors[.jewelCount])
                TextField("Nominal power reserve (hours)", text: field(\.powerReserve))
                    .accessibilityIdentifier("caliberPowerReserve")
                CaliberFieldError(message: calibers.fieldErrors[.powerReserve])
                TextField("Lift angle (degrees)", text: field(\.liftAngle))
                    .accessibilityIdentifier("caliberLiftAngle")
                CaliberFieldError(message: calibers.fieldErrors[.liftAngle])
                TextField("Specification notes", text: field(\.specificationNotes), axis: .vertical)
                    .lineLimit(3...8)
                    .accessibilityIdentifier("caliberSpecificationNotes")
            }
            Section("Source") {
                TextField("Source note", text: field(\.sourceNote), axis: .vertical)
                    .lineLimit(3...8)
                    .accessibilityIdentifier("caliberSourceNote")
                Text(
                    "Record the source for technical claims. A similar designation does not prove parts compatibility."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let error = calibers.saveError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("caliberSaveError")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(calibers.isSaving)
        .navigationTitle(editorTitle)
        .toolbar {
            ToolbarItemGroup(placement: .confirmationAction) {
                if calibers.isSaving { ProgressView().controlSize(.small) }
                Button("Cancel", action: calibers.cancel)
                    .accessibilityIdentifier("cancelCaliber")
                    .disabled(calibers.isSaving)
                Button("Save", action: calibers.saveCommand).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("saveCaliber")
                    .disabled(!calibers.canSave)
            }
        }
        .onAppear(perform: focusDesignation)
    }

    private var editorTitle: String {
        if calibers.selectedID == nil { return "New Caliber" }
        return "Edit Caliber"
    }

    private var movementType: Binding<MovementType> {
        Binding(get: currentMovementType, set: selectMovementType)
    }

    private func currentMovementType() -> MovementType { calibers.draft?.movementType ?? .unknown }
    private func selectMovementType(_ type: MovementType) { calibers.draft?.movementType = type }
    private func focusDesignation() { focusedField = .designation }

    private func field(_ keyPath: WritableKeyPath<CaliberDraft, String>) -> Binding<String> {
        Binding(
            get: { calibers.draft?[keyPath: keyPath] ?? "" },
            set: { calibers.draft?[keyPath: keyPath] = $0 }
        )
    }
}

private struct CaliberFieldError: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityLabel("Field error: \(message)")
        }
    }
}
