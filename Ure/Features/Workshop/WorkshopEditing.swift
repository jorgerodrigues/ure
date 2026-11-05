import Observation

@Observable
final class WorkshopEditing {
    let archive = ArchiveState()
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
            return canWrite(LibraryItemOwner.watch(job.watchID))
        }
    }

    func closeChildren() {
        tasks.close()
        parts.close()
        material.close()
    }

    // Fields that save as you type, such as notes and material titles. They never ask to be
    // saved, so they are not drafts.
    var hasUnsavedFields: Bool { notes.hasUnsavedChanges || material.hasUnsavedTitles }

    func saveFieldsNow() {
        notes.saveNow()
        material.saveTitlesNow()
    }

    func saveAllFields() async -> Bool {
        let notesSaved = await notes.saveAll()
        let titlesSaved = await material.saveAllTitles()
        return notesSaved && titlesSaved
    }

    var isSaving: Bool {
        watches.isSaving || calibers.isSaving || jobs.isSaving || material.isBusy
            || tasks.isSaving || parts.isSaving
    }
    var canCancelDraft: Bool {
        guard !isSaving, !isNavigationPending else { return false }
        return parts.draft != nil || tasks.draft != nil
            || jobs.isEditing || calibers.draft != nil || watches.draft != nil
    }

    func cancelDraft() {
        guard canCancelDraft else { return }
        if parts.draft != nil {
            parts.cancel()
        } else if tasks.draft != nil {
            tasks.cancel()
        } else if jobs.isEditing {
            jobs.cancel()
        } else if calibers.draft != nil {
            calibers.cancel()
        } else {
            watches.cancel()
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
        watches.hasUnsavedChanges || calibers.hasUnsavedChanges || jobs.hasUnsavedChanges
            || tasks.hasUnsavedChanges || parts.hasUnsavedChanges
    }
    var isNavigationPending: Bool {
        watches.isNavigationPending || calibers.isNavigationPending || jobs.isNavigationPending
            || tasks.isNavigationPending || parts.isNavigationPending
    }

    var showsUnsavedChanges: Bool {
        get {
            watches.showsUnsavedChanges || calibers.showsUnsavedChanges || jobs.showsUnsavedChanges
                || tasks.showsUnsavedChanges || parts.showsUnsavedChanges
        }
        set {
            if watches.isNavigationPending {
                watches.showsUnsavedChanges = newValue
            } else if calibers.isNavigationPending {
                calibers.showsUnsavedChanges = newValue
            } else if jobs.isNavigationPending {
                jobs.showsUnsavedChanges = newValue
            } else if tasks.isNavigationPending {
                tasks.showsUnsavedChanges = newValue
            } else {
                parts.showsUnsavedChanges = newValue
            }
        }
    }

    var unsavedChangesTitle: String {
        if watches.isNavigationPending { return "Save changes to this watch?" }
        if calibers.isNavigationPending { return "Save changes to this caliber?" }
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
        watches.requestNavigation(
            {
                self.calibers.requestNavigation(
                    {
                        self.jobs.requestNavigation(
                            {
                                self.tasks.requestNavigation(
                                    {
                                        self.parts.requestNavigation(action, onCancel: onCancel)
                                    }, onCancel: onCancel)
                            },
                            onCancel: onCancel)
                    }, onCancel: onCancel)
            }, onCancel: onCancel)
    }

    func stay() {
        if watches.isNavigationPending {
            watches.stay()
        } else if calibers.isNavigationPending {
            calibers.stay()
        } else if jobs.isNavigationPending {
            jobs.stay()
        } else if tasks.isNavigationPending {
            tasks.stay()
        } else {
            parts.stay()
        }
    }

    func discardAndContinue() {
        if watches.isNavigationPending {
            watches.discardAndContinue()
        } else if calibers.isNavigationPending {
            calibers.discardAndContinue()
        } else if jobs.isNavigationPending {
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
        if watches.isNavigationPending {
            await watches.saveAndContinue()
        } else if calibers.isNavigationPending {
            await calibers.saveAndContinue()
        } else if jobs.isNavigationPending {
            guard canSaveJob else { jobs.stay(); return }
            await jobs.saveAndContinue()
        } else if tasks.isNavigationPending {
            await tasks.saveAndContinue()
        } else {
            await parts.saveAndContinue()
        }
    }
}
