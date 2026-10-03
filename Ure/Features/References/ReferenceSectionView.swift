import SwiftUI

struct ReferenceSectionView: View {
    @State private var searchText = ""
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
                TextField("Filter links", text: $searchText)
                    .accessibilityIdentifier("referencesLocalSearch")
                if references.records(for: owner, matching: searchText).isEmpty {
                    Text(
                        searchText.isEmpty
                            ? "No \(owner.scope.lowercased()) external links yet."
                            : "No matching links."
                    )
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(references.records(for: owner, matching: searchText)) { item in
                        ReferenceRow(item: item, owner: owner)
                    }
                }
            }
            DocumentSectionView(owner: owner)
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
