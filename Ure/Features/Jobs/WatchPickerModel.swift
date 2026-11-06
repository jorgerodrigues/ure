import Foundation
import Observation

// What the watch picker on a job without a watch shows: what you typed, the row Return takes,
// and whether you are typing in it. Picking a row gives the job that watch, opens the watch's
// open job instead, or makes a new watch with the name you typed.
@Observable
final class WatchPickerModel {
    var query = ""
    private(set) var highlighted = 0
    var isEditing = false

    func items(
        watches: [WatchRecord], calibers: [CaliberRecord], jobs: [JobRecord]
    ) -> [WatchPickerItem] {
        WatchPickerMatches.items(for: query, watches: watches, calibers: calibers, jobs: jobs)
    }

    func type(_ text: String) {
        query = text
        highlighted = 0
    }

    // The Down and Up Arrows move the highlight, and it stops at the first and last row.
    func move(by step: Int, count: Int) {
        guard count > 0 else { return }
        highlighted = min(max(highlighted + step, 0), count - 1)
    }

    func highlightedItem(in items: [WatchPickerItem]) -> WatchPickerItem? {
        guard items.indices.contains(highlighted) else { return items.first }
        return items[highlighted]
    }

    func reset() {
        query = ""
        highlighted = 0
    }

    // Gives the selected job the picked watch and selects that watch once it has saved. A watch
    // with an open job opens that job instead, because a watch has one open job at a time. The
    // job being set up goes then, after everything typed before it, when it holds nothing and no
    // typing is left unsaved. False when nothing could be picked.
    @discardableResult
    func pick(_ item: WatchPickerItem, editing: WorkshopEditing, undoManager: UndoManager?)
        -> Bool
    {
        let jobs = editing.jobs
        let watches = editing.watches
        switch item {
        case .watch(let choice) where choice.openJob != nil:
            guard let job = jobs.openOpenJob(of: choice.watch.id, discardingBlank: jobs.selectedID)
            else { return false }
            watches.select(job.watchID)
            reset()
        case .watch(let choice):
            let watchID = choice.watch.id
            let picked = jobs.chooseWatch(watchID, undoManager: undoManager) { [weak self] result in
                guard result.isSaved else { return }
                watches.select(watchID)
                self?.reset()
            }
            return picked != nil
        case .newWatch(let name):
            let picked = jobs.chooseNewWatch(named: name, undoManager: undoManager) {
                [weak self] result in
                for case .job(let job) in result.changes {
                    watches.select(job.watchID)
                    self?.reset()
                }
            }
            return picked != nil
        }
        return true
    }
}
