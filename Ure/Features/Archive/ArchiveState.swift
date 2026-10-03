import Foundation
import Observation

nonisolated enum ArchiveTarget: Hashable, Sendable {
    case watch(UUID)
    case caliber(UUID)
    case job(UUID)
}

nonisolated struct ArchiveEntry: Identifiable, Sendable {
    let id: ArchiveTarget
    let title: String
    let context: String
}

@Observable
final class ArchiveState {
    var searchText = ""
    private(set) var selectedTarget: ArchiveTarget?
    private(set) var navigationRevision = 0
    private(set) var navigationError: String?

    func isShowingCaliber(editing: WorkshopEditing) -> Bool {
        if case .caliber(let id) = selectedTarget { return editing.calibers.selectedID == id }
        return false
    }

    func displayedTarget(editing: WorkshopEditing) -> ArchiveTarget? {
        switch selectedTarget {
        case .caliber(let id):
            if editing.calibers.selectedID == id { return selectedTarget }
        case .watch(let id):
            if editing.watches.selectedID == id { return selectedTarget }
        case .job(let id):
            if let job = editing.jobs.jobs.first(where: { $0.id == id }),
                editing.watches.selectedID == job.watchID
            {
                return selectedTarget
            }
        case nil: break
        }
        return nil
    }

    func records(editing: WorkshopEditing) -> [ArchiveEntry] {
        var entries = editing.watches.watches.filter { $0.archivedAt != nil }.map {
            ArchiveEntry(id: .watch($0.id), title: $0.name, context: "Archived watch")
        }
        entries += editing.calibers.calibers.filter { $0.archivedAt != nil }.map {
            ArchiveEntry(id: .caliber($0.id), title: $0.label, context: "Archived caliber")
        }
        entries += editing.jobs.jobs.filter { !$0.stage.isOpen }.map { job in
            let watch = editing.watches.watches.first { $0.id == job.watchID }
            return ArchiveEntry(
                id: .job(job.id), title: job.title,
                context: "\(watch?.name ?? "Unavailable watch") · \(job.stage.rawValue)")
        }
        return entries.filter { SearchKey.matches([$0.title, $0.context], query: searchText) }
            .sorted {
                let comparison = $0.title.localizedStandardCompare($1.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return String(describing: $0.id) < String(describing: $1.id)
            }
    }

    func open(_ target: ArchiveTarget?, editing: WorkshopEditing) {
        guard let target else { return }
        editing.requestNavigation {
            guard self.records(editing: editing).contains(where: { $0.id == target }) else {
                self.navigationError = "This archive record is unavailable. Retry the archive list."
                return
            }
            editing.closeChildren()
            editing.jobs.close()
            switch target {
            case .watch(let id): editing.watches.select(id)
            case .caliber(let id): editing.calibers.select(id)
            case .job(let id):
                guard let job = editing.jobs.jobs.first(where: { $0.id == id }) else { return }
                editing.watches.select(job.watchID)
                editing.jobs.open(job)
            }
            self.navigationRevision += 1
            self.selectedTarget = target
            self.navigationError = nil
        }
    }
}
