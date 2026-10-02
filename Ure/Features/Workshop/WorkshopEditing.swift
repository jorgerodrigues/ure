import Observation

@Observable
final class WorkshopEditing {
    let watches: WatchState
    let calibers: CaliberState
    let jobs: JobState
    let notes: NoteState
    let references: ReferenceState
    let photos: PhotoState

    init(
        watches: WatchState, calibers: CaliberState, jobs: JobState, notes: NoteState,
        references: ReferenceState, photos: PhotoState
    ) {
        self.watches = watches
        self.calibers = calibers
        self.jobs = jobs
        self.notes = notes
        self.references = references
        self.photos = photos
    }

    var isSaving: Bool {
        watches.isSaving || calibers.isSaving || jobs.isSaving || notes.isSaving
            || references.isSaving || photos.isSaving || photos.isImporting
    }
    var hasUnsavedChanges: Bool {
        watches.hasUnsavedChanges || calibers.hasUnsavedChanges || jobs.hasUnsavedChanges
            || notes.hasUnsavedChanges || references.hasUnsavedChanges || photos.hasUnsavedChanges
    }
    var isNavigationPending: Bool {
        watches.isNavigationPending || calibers.isNavigationPending || jobs.isNavigationPending
            || notes.isNavigationPending || references.isNavigationPending
            || photos.isNavigationPending
    }

    var showsUnsavedChanges: Bool {
        get {
            watches.showsUnsavedChanges || calibers.showsUnsavedChanges || jobs.showsUnsavedChanges
                || notes.showsUnsavedChanges || references.showsUnsavedChanges
                || photos.showsUnsavedChanges
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
            } else {
                photos.showsUnsavedChanges = newValue
            }
        }
    }

    var unsavedChangesTitle: String {
        if watches.isNavigationPending { return "Save changes to this watch?" }
        if calibers.isNavigationPending { return "Save changes to this caliber?" }
        if jobs.isNavigationPending { return "Save changes to this job?" }
        if notes.isNavigationPending { return "Save changes to this note?" }
        if references.isNavigationPending { return "Save changes to this reference?" }
        return "Save changes to this photo?"
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
                                                    action, onCancel: onCancel)
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
        } else {
            photos.stay()
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
        } else {
            photos.discardAndContinue()
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
            await jobs.saveAndContinue()
        } else if notes.isNavigationPending {
            await notes.saveAndContinue()
        } else if references.isNavigationPending {
            await references.saveAndContinue()
        } else {
            await photos.saveAndContinue()
        }
    }
}
