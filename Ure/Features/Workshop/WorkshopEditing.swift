import Observation

@Observable
final class WorkshopEditing {
    let watches: WatchState
    let calibers: CaliberState
    let jobs: JobState
    let notes: RecordNotesState
    let material: MaterialState
    let tasks: JobTaskState
    let parts: PartState

    init(
        watches: WatchState, calibers: CaliberState, jobs: JobState, notes: RecordNotesState,
        material: MaterialState, tasks: JobTaskState, parts: PartState
    ) {
        self.watches = watches
        self.calibers = calibers
        self.jobs = jobs
        self.notes = notes
        self.material = material
        self.tasks = tasks
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
                let job = jobs.jobs.first(where: { $0.id == id }), job.stage.isOpen,
                job.archivedAt == nil
            else { return false }
            // An open job stays open to work on when its watch is archived.
            return !watches.isLoading && watches.loadError == nil
                && watches.watches.contains { $0.id == job.watchID }
        }
    }

    func closeChildren() {
        tasks.close()
        parts.close()
        material.close()
    }

    // Fields that save as you type, such as notes, material titles and the facts on watch and
    // caliber pages. They never ask to be saved, so they are not drafts.
    var hasUnsavedFields: Bool {
        notes.hasUnsavedChanges || material.hasUnsavedTitles || calibers.hasUnsavedFacts
            || watches.hasUnsavedFacts
    }

    func saveFieldsNow() {
        notes.saveNow()
        material.saveTitlesNow()
        calibers.saveFactsNow()
        watches.saveFactsNow()
    }

    func saveAllFields() async -> Bool {
        let notesSaved = await notes.saveAll()
        let titlesSaved = await material.saveAllTitles()
        let caliberFactsSaved = await calibers.saveAllFacts()
        let watchFactsSaved = await watches.saveAllFacts()
        return notesSaved && titlesSaved && caliberFactsSaved && watchFactsSaved
    }

    var isSaving: Bool {
        watches.isSaving || calibers.isSaving || jobs.isSaving || material.isBusy
            || tasks.isSaving || parts.isSaving
    }
    var canCancelDraft: Bool {
        guard !isSaving, !isNavigationPending else { return false }
        return parts.draft != nil || tasks.draft != nil || jobs.isEditing
    }

    func cancelDraft() {
        guard canCancelDraft else { return }
        if parts.draft != nil {
            parts.cancel()
        } else if tasks.draft != nil {
            tasks.cancel()
        } else {
            jobs.cancel()
        }
    }

    var canSaveJob: Bool {
        guard jobs.canSave else { return false }
        if let draft = jobs.actionDraft, draft.action == .transition, !draft.transition.stage.isOpen
        {
            return !tasks.isLoading && tasks.loadError == nil
                && !parts.isLoading && parts.loadError == nil
        }
        return true
    }

    func saveJobCommand() {
        guard canSaveJob else { return }
        jobs.saveCommand()
    }
    var hasUnsavedChanges: Bool {
        jobs.hasUnsavedChanges || tasks.hasUnsavedChanges || parts.hasUnsavedChanges
    }
    var isNavigationPending: Bool {
        jobs.isNavigationPending || tasks.isNavigationPending || parts.isNavigationPending
    }

    var showsUnsavedChanges: Bool {
        get {
            jobs.showsUnsavedChanges || tasks.showsUnsavedChanges || parts.showsUnsavedChanges
        }
        set {
            if jobs.isNavigationPending {
                jobs.showsUnsavedChanges = newValue
            } else if tasks.isNavigationPending {
                tasks.showsUnsavedChanges = newValue
            } else {
                parts.showsUnsavedChanges = newValue
            }
        }
    }

    var unsavedChangesTitle: String {
        if jobs.isNavigationPending { return "Save changes to this job?" }
        if tasks.isNavigationPending { return "Save changes to this task?" }
        return "Save changes to this part?"
    }

    func requestNavigation(_ action: @escaping () -> Void, onCancel: (() -> Void)? = nil) {
        guard !isSaving, !isNavigationPending else {
            onCancel?()
            return
        }
        saveFieldsNow()
        jobs.requestNavigation(
            {
                self.tasks.requestNavigation(
                    {
                        self.parts.requestNavigation(action, onCancel: onCancel)
                    }, onCancel: onCancel)
            },
            onCancel: onCancel)
    }

    func stay() {
        if jobs.isNavigationPending {
            jobs.stay()
        } else if tasks.isNavigationPending {
            tasks.stay()
        } else {
            parts.stay()
        }
    }

    func discardAndContinue() {
        if jobs.isNavigationPending {
            jobs.discardAndContinue()
        } else if tasks.isNavigationPending {
            tasks.discardAndContinue()
        } else {
            parts.discardAndContinue()
        }
    }

    func saveAndContinueCommand() {
        Task { await saveAndContinue() }
    }

    func saveAndContinue() async {
        if jobs.isNavigationPending {
            guard canSaveJob else { jobs.stay(); return }
            await jobs.saveAndContinue()
        } else if tasks.isNavigationPending {
            await tasks.saveAndContinue()
        } else {
            await parts.saveAndContinue()
        }
    }
}
