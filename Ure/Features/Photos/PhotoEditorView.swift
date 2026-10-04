import SwiftUI

struct PhotoEditorView: View {
    @Environment(PhotoState.self) private var photos
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    @FocusState private var titleFocused: Bool
    let owner: LibraryItemOwner

    var body: some View {
        Form {
            Section("\(owner.scope) photo") {
                TextField("Title", text: field(\.title, fallback: "")).focused($titleFocused)
                Picker("Stage", selection: field(\.stage, fallback: .unclassified)) {
                    ForEach(PhotoStage.allCases, id: \.self) { stage in
                        Text(stage.rawValue).tag(stage)
                    }
                }
            }
            Section("Caption (optional)") {
                TextEditor(text: field(\.caption, fallback: "")).frame(minHeight: 160)
                    .accessibilityLabel("Photo caption")
            }
            if let error = photos.saveError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(photos.isSaving || !editing.canWrite(owner))
        .navigationTitle("Edit Photo")
        .toolbar {
            ToolbarItemGroup(placement: .confirmationAction) {
                Button("Cancel", action: photos.cancel).disabled(photos.isSaving)
                Button("Save", action: photos.saveCommand).buttonStyle(.borderedProminent)
                    .disabled(!photos.canSave(jobs: jobs) || !editing.canWrite(owner))
            }
        }
        .onAppear(perform: focusTitle)
    }

    private func field<Value>(_ keyPath: WritableKeyPath<PhotoDraft, Value>, fallback: Value)
        -> Binding<Value>
    {
        Binding(
            get: { photos.draft?[keyPath: keyPath] ?? fallback },
            set: { photos.draft?[keyPath: keyPath] = $0 })
    }
    private func focusTitle() { titleFocused = true }
}
