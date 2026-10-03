import Observation

@Observable
final class WorkshopEditing {
    let archive = ArchiveState()
    let watches: WatchState
    let calibers: CaliberState
    let jobs: JobState
    let notes: NoteState
    let references: ReferenceState
    let photos: PhotoState
    let documents: DocumentState
    let tasks: JobTaskState
    let parts: PartState

    init(
        watches: WatchState, calibers: CaliberState, jobs: JobState, notes: NoteState,
        references: ReferenceState, photos: PhotoState, documents: DocumentState,
        tasks: JobTaskState, parts: PartState
    ) {
        self.watches = watches
        self.calibers = calibers
        self.jobs = jobs
        self.notes = notes
        self.references = references
        self.photos = photos
        self.documents = documents
        self.tasks = tasks
        self.parts = parts
    }

    func canWrite(_ owner: NoteOwner) -> Bool {
        switch owner {
        case .watch(let id): return canWrite(LibraryItemOwner.watch(id))
        case .job(let id): return canWrite(LibraryItemOwner.job(id))
        case .caliber(let id): return canWrite(LibraryItemOwner.caliber(id))
        }
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
        notes.close()
        references.close()
        photos.close()
        documents.close()
    }

    var isSaving: Bool {
        watches.isSaving || calibers.isSaving || jobs.isSaving || notes.isSaving
            || references.isSaving || photos.isSaving || photos.isImporting || documents.isSaving
            || documents.isImporting || tasks.isSaving || parts.isSaving
    }
    var canCancelDraft: Bool {
        guard !isSaving, !isNavigationPending else { return false }
        return parts.draft != nil || tasks.draft != nil || documents.draft != nil
            || photos.draft != nil || references.draft != nil || notes.draft != nil
            || jobs.isEditing || calibers.draft != nil || watches.draft != nil
    }

    func cancelDraft() {
        guard canCancelDraft else { return }
        if parts.draft != nil {
            parts.cancel()
        } else if tasks.draft != nil {
            tasks.cancel()
        } else if documents.draft != nil {
            documents.cancel()
        } else if photos.draft != nil {
            photos.cancel()
        } else if references.draft != nil {
            references.cancel()
        } else if notes.draft != nil {
            notes.cancel()
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
            || notes.hasUnsavedChanges || references.hasUnsavedChanges || photos.hasUnsavedChanges
            || documents.hasUnsavedChanges || tasks.hasUnsavedChanges || parts.hasUnsavedChanges
    }
    var isNavigationPending: Bool {
        watches.isNavigationPending || calibers.isNavigationPending || jobs.isNavigationPending
            || notes.isNavigationPending || references.isNavigationPending
            || photos.isNavigationPending || documents.isNavigationPending
            || tasks.isNavigationPending || parts.isNavigationPending
    }

    var showsUnsavedChanges: Bool {
        get {
            watches.showsUnsavedChanges || calibers.showsUnsavedChanges || jobs.showsUnsavedChanges
                || notes.showsUnsavedChanges || references.showsUnsavedChanges
                || photos.showsUnsavedChanges || documents.showsUnsavedChanges
                || tasks.showsUnsavedChanges || parts.showsUnsavedChanges
        }
        set {
            if watches.isNavigationPending {
                watches.showsUnsavedChanges = newValue
            } else if calibers.isNavigationPending {
                calibers.showsUnsavedChanges = newValue
            } else if jobs.isNavigationPending {
                jobs.showsUnsavedChanges = newValue
            } else if notes.isNavigationPending {
                notes.showsUnsavedChanges = newValue
            } else if references.isNavigationPending {
                references.showsUnsavedChanges = newValue
            } else if photos.isNavigationPending {
                photos.showsUnsavedChanges = newValue
            } else if documents.isNavigationPending {
                documents.showsUnsavedChanges = newValue
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
        if notes.isNavigationPending { return "Save changes to this note?" }
        if references.isNavigationPending { return "Save changes to this reference?" }
        if photos.isNavigationPending { return "Save changes to this photo?" }
        if documents.isNavigationPending { return "Save changes to this document?" }
        if tasks.isNavigationPending { return "Save changes to this task?" }
        return "Save changes to this part?"
    }

    func requestNavigation(_ action: @escaping () -> Void, onCancel: (() -> Void)? = nil) {
        guard !isSaving, !isNavigationPending else {
            onCancel?()
            return
        }
        watches.requestNavigation(
            {
                self.calibers.requestNavigation(
                    {
                        self.jobs.requestNavigation(
                            {
                                self.notes.requestNavigation(
                                    {
                                        self.references.requestNavigation(
                                            {
                                                self.photos.requestNavigation(
                                                    {
                                                        self.documents.requestNavigation(
                                                            {
                                                                self.tasks.requestNavigation(
                                                                    {
                                                                        self.parts
                                                                            .requestNavigation(
                                                                                action,
                                                                                onCancel: onCancel)
                                                                    }, onCancel: onCancel)
                                                            },
                                                            onCancel: onCancel)
                                                    },
                                                    onCancel: onCancel)
                                            }, onCancel: onCancel)
                                    },
                                    onCancel: onCancel)
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
        } else if notes.isNavigationPending {
            notes.stay()
        } else if references.isNavigationPending {
            references.stay()
        } else if photos.isNavigationPending {
            photos.stay()
        } else if documents.isNavigationPending {
            documents.stay()
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
        } else if notes.isNavigationPending {
            notes.discardAndContinue()
        } else if references.isNavigationPending {
            references.discardAndContinue()
        } else if photos.isNavigationPending {
            photos.discardAndContinue()
        } else if documents.isNavigationPending {
            documents.discardAndContinue()
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
        } else if notes.isNavigationPending {
            await notes.saveAndContinue()
        } else if references.isNavigationPending {
            await references.saveAndContinue()
        } else if photos.isNavigationPending {
            await photos.saveAndContinue()
        } else if documents.isNavigationPending {
            await documents.saveAndContinue()
        } else if tasks.isNavigationPending {
            await tasks.saveAndContinue()
        } else {
            await parts.saveAndContinue()
        }
    }
}
