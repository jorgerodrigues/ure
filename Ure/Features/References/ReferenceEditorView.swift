import SwiftUI

struct ReferenceEditorView: View {
    @Environment(ReferenceState.self) private var references
    @FocusState private var titleFocused: Bool
    let owner: LibraryItemOwner

    var body: some View {
        Form {
            Section("\(owner.scope) external reference") {
                TextField("Title", text: field(\.title))
                    .focused($titleFocused)
                    .accessibilityIdentifier("referenceTitle")
                ReferenceFieldError(message: references.fieldErrors[.title])
                TextField("Source URL", text: field(\.sourceURL))
                    .accessibilityIdentifier("referenceURL")
                ReferenceFieldError(message: references.fieldErrors[.sourceURL])
                Text("Use an HTTP or HTTPS URL. The linked content is not saved offline.")
                    .foregroundStyle(.secondary)
            }
            Section("Source description (optional)") {
                TextField("Source description", text: field(\.sourceDescription), axis: .vertical)
                    .lineLimit(3...8)
                    .accessibilityIdentifier("referenceSourceDescription")
            }
            Section("Notes (optional)") {
                TextEditor(text: field(\.notes))
                    .frame(minHeight: 200)
                    .accessibilityLabel("Reference notes")
                    .accessibilityIdentifier("referenceNotes")
            }
            if let error = references.saveError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("referenceSaveError")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(references.isSaving)
        .navigationTitle(editorTitle)
        .toolbar {
            ToolbarItemGroup(placement: .confirmationAction) {
                if references.isSaving { ProgressView().controlSize(.small) }
                Button("Cancel", action: references.cancel).disabled(references.isSaving)
                    .accessibilityIdentifier("cancelReference")
                Button("Save", action: references.saveCommand).disabled(!references.canSave)
                    .accessibilityIdentifier("saveReference")
            }
        }
        .onAppear(perform: focusTitle)
    }

    private var editorTitle: String {
        if references.selectedID == nil { return "New Link" }
        return "Edit Link"
    }

    private func focusTitle() { titleFocused = true }

    private func field(_ keyPath: WritableKeyPath<ReferenceDraft, String>) -> Binding<String> {
        Binding(
            get: { references.draft?[keyPath: keyPath] ?? "" },
            set: { references.draft?[keyPath: keyPath] = $0 })
    }
}

private struct ReferenceFieldError: View {
    let message: String?
    var body: some View {
        if let message {
            Text(message).font(.caption).foregroundStyle(.red)
                .accessibilityLabel("Field error: \(message)")
        }
    }
}
