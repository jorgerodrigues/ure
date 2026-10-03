import Foundation
import GRDB
import Observation

@Observable
final class WorkshopOverviewState {
    private let coordinator: LibraryCoordinator
    private(set) var rows: [WorkshopJob] = []
    private(set) var isLoading = true
    private(set) var loadError: String?
    private(set) var navigationError: String?
    private(set) var observationRevision = 0
    var searchText = ""
    var stageFilter: JobStage?

    init(coordinator: LibraryCoordinator) {
        self.coordinator = coordinator
    }

    var filteredRows: [WorkshopJob] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            if let stageFilter, row.job.stage != stageFilter { return false }
            if query.isEmpty { return true }
            return [
                row.watch.name, row.watch.brand, row.watch.model, row.watch.caseReference,
                row.watch.serial, row.job.title, row.job.waitingReason,
            ].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    func rows(for stage: JobStage) -> [WorkshopJob] {
        filteredRows.filter { $0.job.stage == stage }
    }

    func selectionMessage(for job: JobRecord?) -> String? {
        guard !isLoading, loadError == nil, let job else { return nil }
        if !job.stage.isOpen { return "This job is closed. It remains in watch history." }
        if !filteredRows.contains(where: { $0.id == job.id }) {
            return "The selected job is outside the current filters. Its details remain open."
        }
        return nil
    }

    func observe() async {
        isLoading = true
        loadError = nil
        do {
            let values = try await coordinator.workshopValues()
            for try await rows in values {
                try Task.checkCancellation()
                self.rows = rows
                isLoading = false
            }
        } catch {
            if Task.isCancelled { return }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    func retry() { observationRevision += 1 }

    func clearFilters() {
        searchText = ""
        stageFilter = nil
    }

    func open(_ id: UUID?, editing: WorkshopEditing) {
        guard let id, !isLoading, loadError == nil else { return }
        editing.requestNavigation {
            self.navigationError = nil
            guard self.rows.contains(where: { $0.id == id }),
                !editing.jobs.isLoading, editing.jobs.loadError == nil,
                !editing.watches.isLoading, editing.watches.loadError == nil,
                let job = editing.jobs.jobs.first(where: { $0.id == id }), job.stage.isOpen,
                editing.watches.watches.contains(where: { $0.id == job.watchID })
            else {
                self.navigationError =
                    "The job is unavailable. Retry loading the workshop or open its watch history."
                return
            }
            editing.tasks.close()
            editing.parts.close()
            editing.notes.close()
            editing.references.close()
            editing.photos.close()
            editing.documents.close()
            editing.watches.select(job.watchID)
            editing.jobs.open(job)
        }
    }
}
