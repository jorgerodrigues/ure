import Foundation
import GRDB
import Observation

@Observable
final class JobTimelineState {
    private(set) var entries: [JobTimelineEntry] = []
    private(set) var isLoading = true
    private(set) var loadError: String?
    private(set) var navigationError: String?

    func observe(jobID: UUID, coordinator: LibraryCoordinator) async {
        isLoading = true
        loadError = nil
        do {
            let values = try await coordinator.timelineValues(for: jobID)
            for try await entries in values {
                try Task.checkCancellation()
                self.entries = entries
                isLoading = false
            }
        } catch {
            if Task.isCancelled { return }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    func openSource(
        _ entry: JobTimelineEntry, jobID: UUID, editing: WorkshopEditing,
        onOpen: @escaping () -> Void
    ) {
        guard !isLoading, loadError == nil, let source = entry.source,
            entries.contains(where: { $0.id == entry.id && $0.source == source })
        else { return }
        editing.requestNavigation {
            guard editing.jobs.selectedID == jobID else { return }
            self.navigationError = nil
            let open: () -> Void
            switch source {
            case .job(let id):
                guard id == jobID else { return }
                open = {}
            case .watch(let id):
                guard !editing.watches.isLoading, editing.watches.loadError == nil,
                    editing.watches.watches.contains(where: { $0.id == id })
                else { self.sourceUnavailable(); return }
                open = {
                    editing.jobs.close()
                    editing.watches.select(id)
                }
            case .task(let id):
                guard !editing.tasks.isLoading, editing.tasks.loadError == nil,
                    let task = editing.tasks.records(for: jobID).first(where: { $0.id == id })
                else { self.sourceUnavailable(); return }
                open = { editing.tasks.open(task, for: jobID) }
            case .part(let id):
                guard !editing.parts.isLoading, editing.parts.loadError == nil,
                    let part = editing.parts.records(for: jobID).first(where: { $0.id == id })
                else { self.sourceUnavailable(); return }
                open = { editing.parts.open(part, for: jobID) }
            case .note(let id):
                guard !editing.notes.isLoading, editing.notes.loadError == nil,
                    let note = editing.notes.records(for: .job(jobID)).first(where: { $0.id == id })
                else { self.sourceUnavailable(); return }
                open = { editing.notes.open(note, for: .job(jobID)) }
            }
            editing.tasks.close()
            editing.parts.close()
            editing.notes.close()
            editing.references.close()
            editing.photos.close()
            editing.documents.close()
            open()
            onOpen()
        }
    }

    private func sourceUnavailable() {
        navigationError =
            "The source record is unavailable. Return to the job and retry loading it."
    }
}
