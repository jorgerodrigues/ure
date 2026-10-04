import SwiftUI

struct WatchDetailView: View {
    @Environment(WatchState.self) private var watches
    @Environment(JobState.self) private var jobs
    @Environment(NoteState.self) private var notes
    @Environment(DocumentState.self) private var documents
    @Environment(PhotoState.self) private var photos
    @Environment(ReferenceState.self) private var references

    @Environment(WorkshopNavigation.self) private var navigation
    @Environment(WorkshopEditing.self) private var editing

    var body: some View {
        if watches.draft != nil {
            WatchEditorView()
        } else if let watch = watches.selectedWatch,
            jobs.watchID == watch.id, jobs.selectedID != nil || jobs.draft != nil
        {
            JobDetailView()
        } else if let watch = watches.selectedWatch, documents.isPresenting(for: .watch(watch.id)) {
            DocumentDetailView(owner: .watch(watch.id))
        } else if let watch = watches.selectedWatch, photos.isPresenting(for: .watch(watch.id)) {
            PhotoDetailView(owner: .watch(watch.id))
        } else if let watch = watches.selectedWatch, references.isPresenting(for: .watch(watch.id))
        {
            ReferenceDetailView(owner: .watch(watch.id))
        } else if let watch = watches.selectedWatch, notes.isPresenting(for: .watch(watch.id)) {
            NoteDetailView(owner: .watch(watch.id))
        } else if let watch = watches.selectedWatch {
            Form {
                RecordHeading(title: watch.name, subtitle: watch.condition.rawValue)
                Section {
                    if watch.archivedAt != nil {
                        Label("Archived. Unarchive to make changes.", systemImage: "archivebox")
                    }
                    Button(
                        watch.archivedAt == nil ? "Archive Watch" : "Unarchive Watch",
                        action: toggleArchive
                    )
                    .disabled(
                        editing.isSaving || jobs.isLoading || jobs.loadError != nil
                            || (watch.archivedAt == nil && jobs.openJob(for: watch.id) != nil)
                    )
                    .accessibilityIdentifier("archiveWatch")
                    if watch.archivedAt == nil, jobs.openJob(for: watch.id) != nil {
                        Text("Close the open job before archiving this watch.").foregroundStyle(
                            .secondary)
                    }
                    if let error = watches.saveError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }

                WatchCoverView(watch: watch)
                Section("Identity") {
                    LabeledContent("Name", value: watch.name)
                    WatchValue(label: "Brand", value: watch.brand)
                    WatchValue(label: "Model", value: watch.model)
                    WatchValue(label: "Case reference", value: watch.caseReference)
                    WatchValue(label: "Serial number", value: watch.serial)
                    WatchValue(label: "Approximate year", value: watch.approximateYear)
                }
                Section("Specifications") {
                    WatchValue(label: "Case material", value: watch.caseMaterial)
                    WatchDimension(label: "Case diameter", value: watch.caseDiameter)
                    WatchDimension(label: "Lug width", value: watch.lugWidth)
                    WatchValue(label: "Stated water resistance", value: watch.waterResistance)
                    if let notes = watch.specificationNotes {
                        LabeledContent("Specification notes") {
                            Text(notes)
                        }
                    }
                }
                Section("Shared caliber specifications") {
                    WatchCaliberView(caliberID: watch.caliberID)
                }
                Section("Current condition") {
                    LabeledContent("Condition", value: watch.condition.rawValue)
                    WatchValue(label: "Condition note", value: watch.conditionNote)
                }
                WatchJobHistoryView(watch: watch)
                NoteSectionView(owner: .watch(watch.id))
                PhotoSectionView(owner: .watch(watch.id))
                ReferenceSectionView(owner: .watch(watch.id))
            }
            .formStyle(.grouped)
            .textSelection(.enabled)
            .navigationTitle(navigation.selectedSection.title)
            .focusedSceneValue(\.recordMenuActions, menuActions(for: watch))
            .toolbar {
                Button("Edit", systemImage: "pencil", action: watches.edit)
                    .labelStyle(.iconOnly)
                    .help("Edit Watch (⌥⌘E)")
                    .disabled(editing.isSaving || watch.archivedAt != nil)
                    .accessibilityIdentifier("editWatch")
            }
        } else {
            ContentUnavailableView(
                "Select a watch", systemImage: "watch.analog",
                description: Text("Choose a watch or add a new one.")
            )
        }
    }
    private func toggleArchive() { editing.requestNavigation(watches.toggleArchiveCommand) }

    private func menuActions(for watch: WatchRecord) -> RecordMenuActions {
        guard !editing.isSaving, watch.archivedAt == nil else { return RecordMenuActions() }
        return RecordMenuActions(edit: watches.edit)
    }
}

private struct WatchValue: View {
    let label: String
    let value: String?

    var body: some View {
        LabeledContent(label) {
            if let value {
                Text(value)
            } else {
                Text("Not recorded").foregroundStyle(.tertiary)
            }
        }
    }
}

private struct WatchDimension: View {
    let label: String
    let value: Double?

    var body: some View {
        LabeledContent(label) {
            if let value {
                Text("\(value.formatted()) mm")
            } else {
                Text("Not recorded").foregroundStyle(.tertiary)
            }
        }
    }
}
