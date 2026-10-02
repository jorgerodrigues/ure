import SwiftUI

struct NoteSectionView: View {
    @Environment(NoteState.self) private var notes
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    let owner: NoteOwner

    var body: some View {
        Section("\(owner.scope) notes") {
            if notes.isLoading {
                ProgressView("Loading notes…")
            } else if let error = notes.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                Button("Retry", action: retry)
            } else {
                Button("Add Note", systemImage: "plus", action: create)
                    .disabled(editing.isSaving || !notes.canWrite(owner, jobs: jobs))
                    .accessibilityIdentifier("addNote")
                if notes.records(for: owner).isEmpty {
                    Text("No \(owner.scope.lowercased()) notes yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(notes.records(for: owner)) { note in
                        NoteRow(note: note, owner: owner)
                    }
                }
            }
        }
    }

    private func create() { editing.requestNavigation { notes.create(for: owner) } }
    private func retry() { Task { await notes.observe() } }
}

private struct NoteRow: View {
    @Environment(NoteState.self) private var notes
    @Environment(WorkshopEditing.self) private var editing
    let note: NoteRecord
    let owner: NoteOwner

    var body: some View {
        Button(action: open) {
            HStack {
                Text(note.title)
                Spacer()
                Text(note.kind.rawValue).foregroundStyle(.secondary)
                Text(note.occurredAt, format: .dateTime.year().month().day())
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(editing.isSaving)
        .accessibilityIdentifier("note-\(note.id.uuidString)")
    }

    private func open() { editing.requestNavigation { notes.open(note, for: owner) } }
}
