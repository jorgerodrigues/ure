import Foundation
import GRDB

import Observation

nonisolated struct SearchRequest: Equatable {
    let text: String
    let revision: Int
}

@Observable
final class SearchState {
    private let coordinator: LibraryCoordinator
    var isPresented = false
    var text = ""
    private(set) var results: [SearchResult] = []
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var navigationError: String?
    private(set) var navigationRevision = 0
    private var observationRevision = 0

    init(coordinator: LibraryCoordinator) { self.coordinator = coordinator }

    var request: SearchRequest {
        SearchRequest(text: text, revision: observationRevision)
    }
    var hasQuery: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func results(for kind: SearchKind) -> [SearchResult] { results.filter { $0.kind == kind } }
    func present() { isPresented = true }
    func close() { isPresented = false }
    func retry() { observationRevision += 1 }

    func observe() async {
        let request = request
        results = []
        loadError = nil
        navigationError = nil
        isLoading = hasQuery
        guard hasQuery else { return }
        do {
            let values = try await coordinator.searchValues(text: request.text)
            for try await results in values {
                try Task.checkCancellation()
                guard self.request == request else { return }
                self.results = results
                isLoading = false
            }
        } catch {
            if Task.isCancelled || self.request != request { return }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    func open(_ id: String, editing: WorkshopEditing, navigation: WorkshopNavigation) {
        guard !isLoading, loadError == nil, results.contains(where: { $0.id == id }) else { return }
        editing.requestNavigation {
            self.navigationError = nil
            guard let result = self.results.first(where: { $0.id == id }),
                let openTarget = self.target(result, editing: editing)
            else { self.unavailable(); return }
            if let jobID = result.jobID {
                guard !editing.jobs.isLoading, editing.jobs.loadError == nil,
                    let job = editing.jobs.jobs.first(where: { $0.id == jobID }),
                    job.watchID == result.watchID
                else { self.unavailable(); return }
            }
            if let watchID = result.watchID {
                guard !editing.watches.isLoading, editing.watches.loadError == nil,
                    editing.watches.watches.contains(where: { $0.id == watchID })
                else { self.unavailable(); return }
            }
            if let caliberID = result.caliberID {
                guard !editing.calibers.isLoading, editing.calibers.loadError == nil,
                    editing.calibers.calibers.contains(where: { $0.id == caliberID })
                else { self.unavailable(); return }
            }
            editing.parts.close()
            editing.material.close()
            editing.jobs.close()
            if let caliberID = result.caliberID {
                editing.calibers.searchText = ""
                editing.calibers.select(caliberID)
                navigation.selection = .calibers
            } else if let watchID = result.watchID {
                editing.watches.searchText = ""
                editing.watches.select(watchID)
                navigation.selection = .watches
                if let job = editing.jobs.jobs.first(where: { $0.id == result.jobID }) {
                    editing.jobs.open(job)
                }
            } else if let job = editing.jobs.jobs.first(where: { $0.id == result.jobID }) {
                // A job without a watch yet opens in Jobs.
                editing.watches.select(nil)
                navigation.selection = .jobs
                editing.jobs.open(job)
            }
            openTarget()
            self.navigationRevision += 1
            self.isPresented = false
        }
    }

    private func target(_ result: SearchResult, editing: WorkshopEditing) -> (() -> Void)? {
        switch result.kind {
        case .watch, .caliber, .job:
            return {}
        case .part:
            guard !editing.parts.isLoading, editing.parts.loadError == nil,
                let jobID = result.jobID,
                let part = editing.parts.records(for: jobID).first(where: {
                    $0.id == result.recordID
                })
            else { return nil }
            return { editing.parts.open(part, for: jobID) }
        case .link, .photo, .document:
            guard !editing.material.isLoading, editing.material.loadError == nil,
                let owner = result.itemOwner,
                let record = editing.material.records(for: owner).first(where: {
                    $0.id == result.recordID
                })
            else { return nil }
            // A link opens its record's page. Only an explicit Open sends it to the browser.
            guard record.item.kind != .link else { return {} }
            return { editing.material.open(record, on: owner) }
        }
    }

    private func unavailable() {
        navigationError = "The record is unavailable. Retry search and the record's list."
    }
}
