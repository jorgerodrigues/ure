import SwiftUI

struct NoteDetailView: View {
    @Environment(NoteState.self) private var notes
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    let owner: NoteOwner

    var body: some View {
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
                    if !notes.canWrite(owner, jobs: jobs) {
                        Section { Text("This job is closed. Reopen it to change its notes.") }
                    }
                }
                .formStyle(.grouped)
                .textSelection(.enabled)
                .navigationTitle(note.title)
                .toolbar {
                    Button("Edit Note", action: edit)
                        .disabled(editing.isSaving || !notes.canWrite(owner, jobs: jobs))
                        .accessibilityIdentifier("editNote")
                }
            } else {
                ContentUnavailableView("Note unavailable", systemImage: "note.text")
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back to \(owner.scope)", systemImage: "chevron.left", action: back)
                    .disabled(editing.isSaving)
                    .accessibilityIdentifier("backFromNote")
            }
        }
    }

    private func edit() {
        guard notes.canWrite(owner, jobs: jobs) else { return }
        notes.edit()
    }
    private func back() { editing.requestNavigation(notes.close) }
}
