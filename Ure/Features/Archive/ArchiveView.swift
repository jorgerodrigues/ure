import SwiftUI

struct ArchiveView: View {
    @Environment(WorkshopEditing.self) private var editing

    var body: some View {
        @Bindable var archive = editing.archive
        Group {
            if editing.watches.isLoading || editing.calibers.isLoading || editing.jobs.isLoading {
                ProgressView("Loading archive…")
            } else if let error = loadError {
                ContentUnavailableView {
                    Label("Archive unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry", action: retry)
                }
            } else {
                List(editing.archive.records(editing: editing), selection: selection) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title)
                        Text(entry.context).font(.caption).foregroundStyle(.secondary)
                    }.tag(entry.id)
                }
                .accessibilityIdentifier("archiveList")
                .overlay {
                    if editing.archive.records(editing: editing).isEmpty {
                        ContentUnavailableView(
                            "No archived records", systemImage: "archivebox",
                            description: Text(
                                "Archived watches and calibers, and closed jobs, appear here."))
                    }
                }
                if let error = archive.navigationError {
                    Label(error, systemImage: "exclamationmark.triangle").padding()
                }
            }
        }
        .navigationTitle("Archive")
        .searchable(text: $archive.searchText, prompt: "Filter archive")
        .disabled(editing.isSaving)
    }

    private var loadError: String? {
        editing.watches.loadError ?? editing.calibers.loadError ?? editing.jobs.loadError
    }
    private var selection: Binding<ArchiveTarget?> {
        Binding(get: selectedTarget, set: open)
    }
    private func selectedTarget() -> ArchiveTarget? {
        guard let target = editing.archive.displayedTarget(editing: editing) else { return nil }
        if case .job(let id) = target, editing.jobs.selectedID != id { return nil }
        return target
    }
    private func open(_ target: ArchiveTarget?) { editing.archive.open(target, editing: editing) }
    private func retry() {
        Task { await editing.watches.observe() }
        Task { await editing.calibers.observe() }
        Task { await editing.jobs.observe() }
    }
}
