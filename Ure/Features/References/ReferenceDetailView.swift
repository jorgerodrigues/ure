import SwiftUI

struct ReferenceDetailView: View {
    @Environment(ReferenceState.self) private var references
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    let owner: LibraryItemOwner

    var body: some View {
        Group {
            if references.draft != nil {
                ReferenceEditorView(owner: owner)
            } else if let item = references.selectedReference {
                Form {
                    Section("\(owner.scope) external reference") {
                        LabeledContent("Title", value: item.title)
                        LabeledContent("Source URL") { Text(item.sourceURL) }
                        Text(
                            "Opens in your default browser. The linked content is not saved offline."
                        )
                        .foregroundStyle(.secondary)
                        Button(
                            "Open in Browser", systemImage: "arrow.up.right.square", action: open
                        )
                        .disabled(editing.isSaving)
                        .accessibilityIdentifier("openReference")
                        if let error = references.openError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        }
                        LabeledContent("Created") { Text(item.createdAt, format: .dateTime) }
                        LabeledContent("Updated") { Text(item.updatedAt, format: .dateTime) }
                    }
                    Section("Source description") {
                        Text(item.sourceDescription).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Section("Notes") {
                        Text(item.notes).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !references.canWrite(owner, jobs: jobs) {
                        Section { Text("This job is closed. Reopen it to change its references.") }
                    }
                }
                .formStyle(.grouped)
                .textSelection(.enabled)
                .navigationTitle(item.title)
                .toolbar {
                    Button("Edit Link", action: edit)
                        .disabled(editing.isSaving || !references.canWrite(owner, jobs: jobs))
                        .accessibilityIdentifier("editReference")
                }
            } else {
                ContentUnavailableView("Reference unavailable", systemImage: "link")
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back to \(owner.scope)", systemImage: "chevron.left", action: back)
                    .disabled(editing.isSaving)
                    .accessibilityIdentifier("backFromReference")
            }
        }
    }

    private func edit() {
        guard references.canWrite(owner, jobs: jobs) else { return }
        references.edit()
    }
    private func open() { references.openInBrowser() }
    private func back() { editing.requestNavigation(references.close) }
}
