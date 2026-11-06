import SwiftUI

struct NotesSectionView: View {
    @Environment(RecordNotesState.self) private var notes
    @Environment(WorkshopEditing.self) private var editing
    let owner: LibraryItemOwner
    var style = RecordSectionStyle.form
    // When the record was last edited, shown beside the heading on a page you write on.
    var edited: Date?

    var body: some View {
        Group {
            switch style {
            case .form:
                Section("Notes") { content }
            case .page:
                VStack(alignment: .leading, spacing: PageLayout.headingSpacing) {
                    PageSectionHeading(
                        title: "Notes", detail: edited.map { "Edited \(PageLayout.day($0))" })
                    content
                }
            }
        }
        .task(id: owner, load)
    }

    @ViewBuilder private var content: some View {
        if let field = notes.field(for: owner) {
            NotesEditor(
                field: field, saveError: notes.saveError(for: owner),
                isEditable: editing.canWrite(owner)
            ).id(owner)
        } else if let error = notes.loadErrors[owner] {
            Label(error, systemImage: "exclamationmark.triangle")
            Button("Retry", action: retry)
        } else {
            ProgressView("Loading notes…")
        }
    }

    private func load() async { await notes.load(owner) }
    private func retry() { Task { await notes.load(owner) } }
}

private struct NotesEditor: View {
    let field: AutosaveField
    let saveError: String?
    let isEditable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NotesTextView(field: field, text: field.text, isEditable: isEditable)
                .frame(maxWidth: NotesLayout.maximumWidth, alignment: .leading)
                .overlay(alignment: .topLeading) {
                    if field.text.isEmpty {
                        NotesPrompt(isEditable: isEditable)
                    }
                }
            if let error = saveError {
                NotesSaveFailure(message: error, retry: field.saveNow)
            } else if field.isEditing {
                Text("Saved as you type · Esc undoes this field")
                    .font(.system(size: NotesLayout.hintSize))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct NotesPrompt: View {
    let isEditable: Bool

    var body: some View {
        Text(isEditable ? "Add notes" : "No notes")
            .font(.system(size: NotesLayout.textSize))
            .foregroundStyle(.tertiary)
            .frame(height: NotesLayout.lineHeight)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct NotesSaveFailure: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Label {
                Text("Your notes did not save. They are still here. \(message)")
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
            }
            .font(.system(size: NotesLayout.failureSize))
            .foregroundStyle(.red)
            Button("Try Again", action: retry)
                .controlSize(.small)
                .accessibilityIdentifier("retryNotesSave")
        }
        .accessibilityElement(children: .contain)
    }
}

enum NotesLayout {
    static let textSize: CGFloat = 15
    static let lineHeight: CGFloat = 24
    static let maximumWidth: CGFloat = 600
    static let hintSize: CGFloat = 11
    static let failureSize: CGFloat = 12
}
