import Foundation
import GRDB
import Observation

@Observable
final class PartsOverviewState {
    private let coordinator: LibraryCoordinator
    private(set) var rows: [OverviewPart] = []
    private(set) var isLoading = true
    private(set) var loadError: String?
    private(set) var navigationError: String?
    private(set) var observationRevision = 0
    var searchText = ""
    var statusFilter: PartStatus?

    init(coordinator: LibraryCoordinator) { self.coordinator = coordinator }

    var filteredRows: [OverviewPart] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            if let statusFilter, row.part.status != statusFilter { return false }
            if query.isEmpty { return true }
            return SearchKey.matches(
                [
                    row.searchKey, row.watch.name,
                    row.watch.brand, row.watch.model, row.watch.caseReference, row.watch.serial,
                    row.job.title,
                ], query: query)
        }
    }

    func selectionMessage(part: PartRequirement?, job: JobRecord?) -> String? {
        guard !isLoading, loadError == nil, let part, let job, part.record.jobID == job.id else {
            return nil
        }
        if !job.stage.isOpen { return "This job is closed. Its parts remain in watch history." }
        if !filteredRows.contains(where: { $0.id == part.id }) {
            return "The selected part is outside the current filters. Its details remain open."
        }
        return nil
    }

    func selectedID(editing: WorkshopEditing) -> UUID? {
        guard let job = editing.jobs.selectedJob, job.watchID == editing.watches.selectedID,
            let part = editing.parts.selectedPart, part.record.jobID == job.id
        else { return nil }
        return part.id
    }

    func observe() async {
        isLoading = true
        loadError = nil
        do {
            let values = try await coordinator.partsOverviewValues()
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
        statusFilter = nil
    }

    func open(_ id: UUID?, editing: WorkshopEditing) {
        guard let id, !isLoading, loadError == nil else { return }
        editing.requestNavigation {
            self.navigationError = nil
            guard let row = self.rows.first(where: { $0.id == id }),
                !editing.parts.isLoading, editing.parts.loadError == nil,
                !editing.jobs.isLoading, editing.jobs.loadError == nil,
                !editing.watches.isLoading, editing.watches.loadError == nil,
                let part = editing.parts.parts.first(where: { $0.id == id }),
                part.record.jobID == row.job.id,
                let job = editing.jobs.jobs.first(where: { $0.id == part.record.jobID }),
                job.stage.isOpen, job.watchID == row.watch.id,
                editing.watches.watches.contains(where: { $0.id == job.watchID })
            else {
                self.navigationError =
                    "The part is unavailable. Retry loading parts or open its watch history."
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
            editing.parts.open(part, for: job.id)
        }
    }
}
