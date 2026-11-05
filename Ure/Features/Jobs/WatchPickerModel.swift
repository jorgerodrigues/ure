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

    // Gives the selected job the picked watch and selects that watch. A watch with an open job
    // opens that job instead, because a watch has one open job at a time. The job being set up
    // goes then only once every field has saved and it holds nothing. True when the job page
    // now shows a job with a watch.
    @discardableResult
    func pick(
        _ item: WatchPickerItem, editing: WorkshopEditing, undoManager: UndoManager?
    ) async -> Bool {
        let jobs = editing.jobs
        let watches = editing.watches
        switch item {
        case .watch(let choice) where choice.openJob != nil:
            let saved = await editing.saveAllFields()
            guard
                let job = await jobs.openOpenJob(
                    of: choice.watch.id, discardingBlank: saved && !editing.hasUnsavedFields)
            else { return false }
            watches.select(job.watchID)
        case .watch(let choice):
            guard await jobs.chooseWatch(choice.watch.id, undoManager: undoManager) else {
                return false
            }
            watches.select(choice.watch.id)
        case .newWatch(let name):
            guard let watchID = await jobs.chooseNewWatch(named: name, undoManager: undoManager)
            else { return false }
            watches.select(watchID)
        }
        reset()
        return true
    }
}
