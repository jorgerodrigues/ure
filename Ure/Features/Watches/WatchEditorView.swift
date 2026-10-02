import SwiftUI

struct WatchEditorView: View {
    @Environment(WatchState.self) private var watches
    @FocusState private var focusedField: WatchField?

    var body: some View {
        Form {
            Section("Identity") {
                WatchTextField("Name", text: field(\.name), identifier: "watchName")
                    .focused($focusedField, equals: .name)
                WatchFieldError(message: watches.fieldErrors[.name])
                WatchTextField("Brand", text: field(\.brand), identifier: "watchBrand")
                WatchTextField("Model", text: field(\.model), identifier: "watchModel")
                WatchTextField(
                    "Case reference", text: field(\.caseReference), identifier: "watchCaseReference"
                )
                WatchTextField("Serial number", text: field(\.serial), identifier: "watchSerial")
                WatchTextField(
                    "Approximate year", text: field(\.approximateYear), identifier: "watchYear")
            }
            Section("Specifications") {
                WatchTextField(
                    "Case material", text: field(\.caseMaterial), identifier: "watchCaseMaterial")
                WatchTextField(
                    "Case diameter (mm)", text: field(\.caseDiameter),
                    identifier: "watchCaseDiameter"
                )
                .focused($focusedField, equals: .caseDiameter)
                WatchFieldError(message: watches.fieldErrors[.caseDiameter])
                WatchTextField(
                    "Lug width (mm)", text: field(\.lugWidth), identifier: "watchLugWidth"
                )
                .focused($focusedField, equals: .lugWidth)
                WatchFieldError(message: watches.fieldErrors[.lugWidth])
                WatchTextField(
                    "Stated water resistance", text: field(\.waterResistance),
                    identifier: "watchWaterResistance")
                Text("This value is a specification. It does not confirm a current pressure test.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Specification notes", text: field(\.specificationNotes), axis: .vertical)
                    .lineLimit(3...8)
                    .accessibilityIdentifier("watchSpecificationNotes")
            }
            if let error = watches.saveError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("watchSaveError")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(watches.isSaving)
        .navigationTitle(editorTitle)
        .toolbar {
            ToolbarItemGroup(placement: .confirmationAction) {
                if watches.isSaving { ProgressView().controlSize(.small) }
                Button("Cancel", action: watches.cancel)
                    .accessibilityIdentifier("cancelWatch")
                    .disabled(watches.isSaving)
                Button("Save", action: watches.saveCommand)
                    .accessibilityIdentifier("saveWatch")
                    .disabled(!watches.canSave)
            }
        }
        .onAppear(perform: focusName)
    }

    private var editorTitle: String {
        if watches.selectedID == nil { return "New Watch" }
        return "Edit Watch"
    }

    private func focusName() { focusedField = .name }

    private func field(_ keyPath: WritableKeyPath<WatchDraft, String>) -> Binding<String> {
        Binding(
            get: { watches.draft?[keyPath: keyPath] ?? "" },
            set: { watches.draft?[keyPath: keyPath] = $0 }
        )
    }
}

private struct WatchTextField: View {
    let title: String
    @Binding var text: String
    let identifier: String

    init(_ title: String, text: Binding<String>, identifier: String) {
        self.title = title
        _text = text
        self.identifier = identifier
    }

    var body: some View {
        TextField(title, text: $text)
            .accessibilityIdentifier(identifier)
    }
}

private struct WatchFieldError: View {
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
