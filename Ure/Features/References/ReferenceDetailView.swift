import SwiftUI

struct ReferenceDetailView: View {
    @Environment(ReferenceState.self) private var references
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    let owner: LibraryItemOwner

    var body: some View {
        @Bindable var references = references
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
                    if !editing.canWrite(owner) {
                        Section {
                            Text("Unarchive the owner or reopen the job to change its references.")
                        }
                    }
                }
                .formStyle(.grouped)
                .textSelection(.enabled)
                .navigationTitle(item.title)
                .toolbar {
                    Button("Remove Link", role: .destructive, action: requestRemoval)
                        .disabled(editing.isSaving || !editing.canWrite(owner))
                        .accessibilityIdentifier("removeLink")
                    Button("Edit Link", systemImage: "pencil", action: edit)
                        .labelStyle(.iconOnly)
                        .help("Edit Link (⌥⌘E)")
                        .disabled(editing.isSaving || !editing.canWrite(owner))
                        .accessibilityIdentifier("editReference")
                }
            } else {
                ContentUnavailableView("Reference unavailable", systemImage: "link")
            }
        }
        .alert("Remove this link?", isPresented: $references.showsRemovalConfirmation) {
            Button("Remove", role: .destructive, action: references.removeCommand)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This link will be removed. This cannot be undone.")
        }
        .safeAreaInset(edge: .bottom) {
            if let error = references.saveError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    .padding()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back to \(owner.scope)", systemImage: "chevron.left", action: back)
                    .disabled(editing.isSaving)
                    .accessibilityIdentifier("backFromReference")
            }
        }
        .focusedSceneValue(\.recordMenuActions, menuActions)
        .focusedSceneValue(\.recordBackAction, backAction)
    }

    private var menuActions: RecordMenuActions {
        guard references.draft == nil, references.selectedReference != nil, !editing.isSaving,
            editing.canWrite(owner)
        else { return RecordMenuActions() }
        return RecordMenuActions(edit: edit, remove: requestRemoval)
    }

    private func requestRemoval() {
        guard editing.canWrite(owner) else { return }
        editing.requestNavigation(references.requestRemoval)
    }
    private func edit() {
        guard editing.canWrite(owner) else { return }
        references.edit()
    }
    private func open() { references.openInBrowser() }
    private var backAction: (() -> Void)? {
        guard !editing.isSaving else { return nil }
        return back
    }

    private func back() { editing.requestNavigation(references.close) }
}
