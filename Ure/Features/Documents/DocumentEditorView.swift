import SwiftUI

struct DocumentEditorView: View {
    @Environment(DocumentState.self) private var documents
    @Environment(JobState.self) private var jobs
    @FocusState private var titleFocused: Bool
    let owner: LibraryItemOwner

    var body: some View {
        Form {
            Section("\(owner.scope) PDF document") {
                TextField("Title", text: field(\.title)).focused($titleFocused)
                    .accessibilityIdentifier("documentTitle")
                DocumentFieldError(message: documents.fieldErrors[.title])
                TextField("Source URL (optional)", text: field(\.sourceURL))
                    .accessibilityIdentifier("documentURL")
                DocumentFieldError(message: documents.fieldErrors[.sourceURL])
                Text(
                    "The PDF stays available offline. A source URL opens only when you choose Open Source."
                )
                .foregroundStyle(.secondary)
            }
            Section("Source description (optional)") {
                TextField("Source description", text: field(\.sourceDescription), axis: .vertical)
                    .lineLimit(3...8)
            }
            Section("Notes (optional)") {
                TextEditor(text: field(\.notes)).frame(minHeight: 160)
                    .accessibilityLabel("Document notes")
            }
            if !documents.canWrite(owner, jobs: jobs) {
                Section { Text("This job is closed. Reopen it to edit this document.") }
            }
            if let error = documents.saveError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(documents.isSaving)
        .navigationTitle("Edit Document")
        .toolbar {
            ToolbarItemGroup(placement: .confirmationAction) {
                Button("Cancel", action: documents.cancel).disabled(documents.isSaving)
                Button("Save", action: documents.saveCommand).disabled(
                    !documents.canSave(jobs: jobs))
            }
        }
        .onAppear(perform: focusTitle)
    }

    private func field(_ keyPath: WritableKeyPath<DocumentDraft, String>) -> Binding<String> {
        Binding(
            get: { documents.draft?[keyPath: keyPath] ?? "" },
            set: { documents.draft?[keyPath: keyPath] = $0 })
    }
    private func focusTitle() { titleFocused = true }
}

private struct DocumentFieldError: View {
    let message: String?
    var body: some View {
        if let message {
            Text(message).font(.caption).foregroundStyle(.red)
                .accessibilityLabel("Field error: \(message)")
        }
    }
}
