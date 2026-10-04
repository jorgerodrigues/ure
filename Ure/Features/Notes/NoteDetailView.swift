import SwiftUI

struct NoteDetailView: View {
    @Environment(NoteState.self) private var notes
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    let owner: NoteOwner

    var body: some View {
        @Bindable var notes = notes
        Group {
            if notes.draft != nil {
                NoteEditorView(owner: owner)
            } else if let note = notes.selectedNote {
                Form {
                    Section("\(owner.scope) note") {
                        LabeledContent("Title", value: note.title)
                        LabeledContent("Kind", value: note.kind.rawValue)
                        LabeledContent("Occurred") { Text(note.occurredAt, format: .dateTime) }
                        LabeledContent("Created") { Text(note.createdAt, format: .dateTime) }
                        LabeledContent("Updated") { Text(note.updatedAt, format: .dateTime) }
                    }
                    Section("Text") {
                        Text(note.body).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !editing.canWrite(owner) {
                        Section {
                            Text("Unarchive the owner or reopen the job to change this note.")
                        }
                    }
                }
                .formStyle(.grouped)
                .textSelection(.enabled)
                .navigationTitle(note.title)
                .toolbar {
                    Button("Remove Note", role: .destructive, action: requestRemoval)
                        .disabled(editing.isSaving || !editing.canWrite(owner))
                        .accessibilityIdentifier("removeNote")
                    Button("Edit Note", systemImage: "pencil", action: edit)
                        .labelStyle(.iconOnly)
                        .help("Edit Note (⌥⌘E)")
                        .disabled(editing.isSaving || !editing.canWrite(owner))
                        .accessibilityIdentifier("editNote")
                }
            } else {
                ContentUnavailableView("Note unavailable", systemImage: "note.text")
            }
        }
        .alert("Remove this note?", isPresented: $notes.showsRemovalConfirmation) {
            Button("Remove", role: .destructive, action: notes.removeCommand)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This note will be removed. This cannot be undone.")
        }
        .safeAreaInset(edge: .bottom) {
            if let error = notes.saveError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    .padding()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back to \(owner.scope)", systemImage: "chevron.left", action: back)
                    .disabled(editing.isSaving)
                    .accessibilityIdentifier("backFromNote")
            }
        }
        .focusedSceneValue(\.recordMenuActions, menuActions)
        .focusedSceneValue(\.recordBackAction, backAction)
    }

    private var menuActions: RecordMenuActions {
        guard notes.draft == nil, notes.selectedNote != nil, !editing.isSaving,
            editing.canWrite(owner)
        else { return RecordMenuActions() }
        return RecordMenuActions(edit: edit, remove: requestRemoval)
    }

    private func requestRemoval() {
        guard editing.canWrite(owner) else { return }
        editing.requestNavigation(notes.requestRemoval)
    }
    private func edit() {
        guard editing.canWrite(owner) else { return }
        notes.edit()
    }
    private var backAction: (() -> Void)? {
        guard !editing.isSaving else { return nil }
        return back
    }

    private func back() { editing.requestNavigation(notes.close) }
}
