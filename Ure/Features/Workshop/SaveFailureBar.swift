import SwiftUI

// A save failed, and the changes made after it wait in order. One bar across the record side of
// the window says so, with Try Again and Discard Unsaved Changes. Discard asks first, because
// it can't be undone.
struct SaveFailureBar: View {
    @Environment(WorkshopEditing.self) private var editing
    @State private var asksToDiscard = false

    var body: some View {
        if let failure = editing.failure {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label {
                    Text(
                        "Your changes are not saving. They are still on screen and will save in order once Try Again works. \(failure)"
                    )
                    .lineLimit(SaveFailureLayout.lines)
                    .help(failure)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.system(size: NotesLayout.failureSize))
                .foregroundStyle(.red)
                Spacer(minLength: 8)
                Button("Try Again", action: editing.tryAgain)
                    .controlSize(.small)
                    .accessibilityIdentifier("tryAgainSaving")
                Button("Discard Unsaved Changes…", action: askToDiscard)
                    .controlSize(.small)
                    .accessibilityIdentifier("discardUnsavedChanges")
            }
            .padding(.horizontal, SaveFailureLayout.inset)
            .padding(.vertical, SaveFailureLayout.verticalInset)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("saveFailureBar")
            .alert("Discard unsaved changes?", isPresented: $asksToDiscard) {
                Button("Discard", role: .destructive, action: editing.discardUnsaved)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Everything since the last change that saved goes, and Undo starts over. You can’t undo this."
                )
            }
        }
    }

    private func askToDiscard() { asksToDiscard = true }
}

enum SaveFailureLayout {
    static let inset: CGFloat = 16
    static let verticalInset: CGFloat = 8
    // A long reason, such as a database error, is cut after this many lines. Its help tag shows
    // all of it.
    static let lines = 3
}
