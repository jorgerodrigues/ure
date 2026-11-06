import Observation

@Observable
final class WorkshopEditing {
    let watches: WatchState
    let calibers: CaliberState
    let jobs: JobState
    let notes: RecordNotesState
    let material: MaterialState
    let checklist: ChecklistState
    let parts: PartState

    init(
        watches: WatchState, calibers: CaliberState, jobs: JobState, notes: RecordNotesState,
        material: MaterialState, checklist: ChecklistState, parts: PartState
    ) {
        self.watches = watches
        self.calibers = calibers
        self.jobs = jobs
        self.notes = notes
        self.material = material
        self.checklist = checklist
        self.parts = parts
    }

    func canWrite(_ owner: LibraryItemOwner) -> Bool {
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
        guard !parts.isLoading, parts.loadError == nil else { return false }
        guard let jobID = part.jobID else { return true }
        return canWrite(.job(jobID))
    }

    func closeChildren() {
        parts.close()
        material.close()
    }

    // Fields that save as you type, such as notes, material titles, the facts on watch,
    // caliber, job and part pages, and checklists. They never ask to be saved, so nothing is a
    // draft.
    var hasUnsavedFields: Bool {
        notes.hasUnsavedChanges || material.hasUnsavedTitles || calibers.hasUnsavedFacts
            || watches.hasUnsavedFacts || jobs.hasUnsavedFacts || checklist.hasUnsavedChanges
            || parts.hasUnsavedFacts
    }

    func saveFieldsNow() {
        notes.saveNow()
        material.saveTitlesNow()
        calibers.saveFactsNow()
        watches.saveFactsNow()
        jobs.saveFactsNow()
        checklist.saveNow()
        parts.saveFactsNow()
    }

    func saveAllFields() async -> Bool {
        let notesSaved = await notes.saveAll()
        let titlesSaved = await material.saveAllTitles()
        let caliberFactsSaved = await calibers.saveAllFacts()
        let watchFactsSaved = await watches.saveAllFacts()
        let jobFactsSaved = await jobs.saveAllFacts()
        let checklistsSaved = await checklist.saveAll()
        let partFactsSaved = await parts.saveAllFacts()
        return notesSaved && titlesSaved && caliberFactsSaved && watchFactsSaved
            && jobFactsSaved && checklistsSaved && partFactsSaved
    }

    var isSaving: Bool {
        watches.isSaving || calibers.isSaving || jobs.isSaving || material.isBusy
            || parts.isSaving
    }

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
