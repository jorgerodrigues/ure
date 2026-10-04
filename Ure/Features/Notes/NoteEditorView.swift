import SwiftUI

struct NoteEditorView: View {
    @Environment(NoteState.self) private var notes
    @Environment(WorkshopEditing.self) private var editing
    @FocusState private var titleFocused: Bool
    let owner: NoteOwner

    var body: some View {
        Form {
            Section("\(owner.scope) note") {
                TextField("Title", text: field(\.title))
                    .focused($titleFocused)
                    .accessibilityIdentifier("noteTitle")
                NoteFieldError(message: notes.fieldErrors[.title])
                Picker("Kind", selection: kind) {
                    ForEach(NoteKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                }
                DatePicker(
                    "Occurred", selection: occurredAt, displayedComponents: [.date, .hourAndMinute]
                )
                .accessibilityIdentifier("noteOccurredAt")
                NoteFieldError(message: notes.fieldErrors[.occurredAt])
            }
            Section("Plain text") {
                TextEditor(text: field(\.body))
                    .frame(minHeight: 250)
                    .accessibilityLabel("Note text")
                    .accessibilityIdentifier("noteBody")
            }
            if let error = notes.saveError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("noteSaveError")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(notes.isSaving || !editing.canWrite(owner))
        .navigationTitle(editorTitle)
        .toolbar {
            ToolbarItemGroup(placement: .confirmationAction) {
                if notes.isSaving { ProgressView().controlSize(.small) }
                Button("Cancel", action: notes.cancel).disabled(notes.isSaving)
                    .accessibilityIdentifier("cancelNote")
                Button("Save", action: notes.saveCommand).buttonStyle(.borderedProminent).disabled(
                    !notes.canSave || !editing.canWrite(owner)
                )
                .accessibilityIdentifier("saveNote")
            }
        }
        .onAppear(perform: focusTitle)
    }

    private var editorTitle: String {
        if notes.selectedID == nil { return "New Note" }
        return "Edit Note"
    }

    private var kind: Binding<NoteKind> { Binding(get: currentKind, set: selectKind) }
    private func currentKind() -> NoteKind { notes.draft?.kind ?? .observation }
    private func selectKind(_ kind: NoteKind) { notes.draft?.kind = kind }
    private var occurredAt: Binding<Date> { Binding(get: currentDate, set: selectDate) }
    private func currentDate() -> Date { notes.draft?.occurredAt ?? Date() }
    private func selectDate(_ date: Date) { notes.draft?.occurredAt = date }
    private func focusTitle() { titleFocused = true }

    private func field(_ keyPath: WritableKeyPath<NoteDraft, String>) -> Binding<String> {
        Binding(
            get: { notes.draft?[keyPath: keyPath] ?? "" },
            set: { notes.draft?[keyPath: keyPath] = $0 })
    }
}

private struct NoteFieldError: View {
    let message: String?
    var body: some View {
        if let message {
            Text(message).font(.caption).foregroundStyle(.red)
                .accessibilityLabel("Field error: \(message)")
        }
    }
}
