import SwiftUI

struct WatchDetailView: View {
    @Environment(WatchState.self) private var watches
    @Environment(JobState.self) private var jobs
    @Environment(NoteState.self) private var notes
    @Environment(ReferenceState.self) private var references

    var body: some View {
        if watches.draft != nil {
            WatchEditorView()
        } else if let watch = watches.selectedWatch,
            jobs.watchID == watch.id, jobs.selectedID != nil || jobs.draft != nil
        {
            JobDetailView()
        } else if let watch = watches.selectedWatch, references.isPresenting(for: .watch(watch.id))
        {
            ReferenceDetailView(owner: .watch(watch.id))
        } else if let watch = watches.selectedWatch, notes.isPresenting(for: .watch(watch.id)) {
            NoteDetailView(owner: .watch(watch.id))
        } else if let watch = watches.selectedWatch {
            Form {
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
                ReferenceSectionView(owner: .watch(watch.id))
            }
            .formStyle(.grouped)
            .textSelection(.enabled)
            .navigationTitle(watch.name)
            .toolbar {
                Button("Edit", action: watches.edit)
                    .accessibilityIdentifier("editWatch")
            }
        } else {
            ContentUnavailableView(
                "Select a watch", systemImage: "watch.analog",
                description: Text("Choose a watch or add a new one.")
            )
        }
    }
}

private struct WatchValue: View {
    let label: String
    let value: String?

    var body: some View {
        LabeledContent(label, value: value ?? "Unknown")
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
                Text("Unknown")
            }
        }
    }
}
