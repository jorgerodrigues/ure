import SwiftUI

struct ReferenceSectionView: View {
    @Environment(ReferenceState.self) private var references
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    let owner: LibraryItemOwner

    var body: some View {
        Section("\(owner.scope) references") {
            if references.isLoading {
                ProgressView("Loading references…")
            } else if let error = references.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                Button("Retry", action: retry)
            } else {
                Button("Add Link", systemImage: "plus", action: create)
                    .disabled(editing.isSaving || !references.canWrite(owner, jobs: jobs))
                    .accessibilityIdentifier("addReference")
                if references.records(for: owner).isEmpty {
                    Text("No \(owner.scope.lowercased()) references yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(references.records(for: owner)) { item in
                        ReferenceRow(item: item, owner: owner)
                    }
                }
            }
        }
    }

    private func create() { editing.requestNavigation { references.create(for: owner) } }
    private func retry() { Task { await references.observe() } }
}

private struct ReferenceRow: View {
    @Environment(ReferenceState.self) private var references
    @Environment(WorkshopEditing.self) private var editing
    let item: LibraryItem
    let owner: LibraryItemOwner

    var body: some View {
        Button(action: select) {
            HStack {
                Text(item.title)
                Spacer()
                Label("External reference", systemImage: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(editing.isSaving)
        .accessibilityIdentifier("reference-\(item.id.uuidString)")
    }

    private func select() { editing.requestNavigation { references.open(item, for: owner) } }
}
