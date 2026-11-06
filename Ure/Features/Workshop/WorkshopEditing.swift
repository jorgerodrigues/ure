import Observation

@Observable
final class WorkshopEditing {
    let queue: EditQueue
    let watches: WatchState
    let calibers: CaliberState
    let jobs: JobState
    let notes: RecordNotesState
    let material: MaterialState
    let checklist: ChecklistState
    let parts: PartState

    init(
        queue: EditQueue, watches: WatchState, calibers: CaliberState, jobs: JobState,
        notes: RecordNotesState, material: MaterialState, checklist: ChecklistState,
        parts: PartState
    ) {
        self.queue = queue
        self.watches = watches
        self.calibers = calibers
        self.jobs = jobs
        self.notes = notes
        self.material = material
        self.checklist = checklist
        self.parts = parts
    }

    // Whether a record page takes edits. While its deletion or archive waits or runs, it does not,
    // because an edit to it would fail for good after that. While the queue is stopped with a
    // change waiting that the screen does not show yet, no page does.
    func canWrite(_ owner: LibraryItemOwner) -> Bool {
        guard !queue.holdsRecords, !queue.isEnding(EndedRecord(owner)) else { return false }
        switch owner {
        case .watch(let id):
            return !watches.isLoading && watches.loadError == nil
                && watches.watches.contains { $0.id == id && $0.archivedAt == nil }
        case .caliber(let id):
            return !calibers.isLoading && calibers.loadError == nil
                && calibers.calibers.contains { $0.id == id && $0.archivedAt == nil }
        case .job(let id):
            guard !jobs.isLoading, jobs.loadError == nil,
                let job = jobs.jobs.first(where: { $0.id == id }), job.archivedAt == nil
            else { return false }
            // A job stays open to work on when it is Done, when its watch is archived, and while
            // it has no watch yet.
            guard !watches.isLoading, watches.loadError == nil else { return false }
            guard let watchID = job.watchID else { return true }
            return watches.watches.contains { $0.id == watchID }
        }
    }

    // A part on a job can change while its job can. A spare in the drawer always can.
    func canWrite(_ part: PartRecord) -> Bool {
        guard !queue.holdsRecords, !queue.isEnding(.part(part.id)), !parts.isLoading,
            parts.loadError == nil
        else { return false }
        guard let jobID = part.jobID else { return true }
        return canWrite(.job(jobID))
    }

    func closeChildren() {
        parts.close()
        material.close()
    }

    // Text on screen that has not saved, in fields that save as you type, such as notes,
    // material titles, the facts on watch, caliber, job and part pages, and checklists. They
    // never ask to be saved, so nothing is a draft.
    var hasUnsavedFields: Bool { queue.hasUnsavedTyping }

    // Submits the typing on screen now, as leaving a page does.
    func saveFieldsNow() { queue.flushTyping() }

    // The one wait before quitting, closing the window, restoring and exporting a backup: every
    // field saves, and every change waiting in the queue runs, until nothing waits or a save
    // fails.
    func saveAllFields() async -> SaveOutcome { await queue.saveEverything() }

    // A save failed, and the changes after it wait. The message says why.
    var failure: String? { queue.failure }

    // Try Again runs the failed save once more, and then the changes that wait.
    func tryAgain() { queue.retry() }

    // Drops every change that did not save, and shows what the library holds.
    func discardUnsaved() { queue.discardUnsaved() }

    // A change other than typing is still saving, or a file is being copied out.
    var isSaving: Bool { queue.isBusy || material.isExporting }

    // Leaving a page saves what you typed on it and asks nothing. Nothing moves while a change
    // is still saving.
    func requestNavigation(_ action: @escaping () -> Void, onCancel: (() -> Void)? = nil) {
        guard !isSaving else {
            onCancel?()
            return
        }
        saveFieldsNow()
        action()
    }
}
