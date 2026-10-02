import Observation

@Observable
final class WorkshopEditing {
    let watches: WatchState
    let calibers: CaliberState
    let jobs: JobState

    init(watches: WatchState, calibers: CaliberState, jobs: JobState) {
        self.watches = watches
        self.calibers = calibers
        self.jobs = jobs
    }

    var isSaving: Bool { watches.isSaving || calibers.isSaving || jobs.isSaving }
    var hasUnsavedChanges: Bool {
        watches.hasUnsavedChanges || calibers.hasUnsavedChanges || jobs.hasUnsavedChanges
    }
    var isNavigationPending: Bool {
        watches.isNavigationPending || calibers.isNavigationPending || jobs.isNavigationPending
    }

    var showsUnsavedChanges: Bool {
        get {
            watches.showsUnsavedChanges || calibers.showsUnsavedChanges || jobs.showsUnsavedChanges
        }
        set {
            if watches.isNavigationPending {
                watches.showsUnsavedChanges = newValue
            } else if calibers.isNavigationPending {
                calibers.showsUnsavedChanges = newValue
            } else {
                jobs.showsUnsavedChanges = newValue
            }
        }
    }

    var unsavedChangesTitle: String {
        if watches.isNavigationPending { return "Save changes to this watch?" }
        if calibers.isNavigationPending { return "Save changes to this caliber?" }
        return "Save changes to this job?"
    }

    func requestNavigation(_ action: @escaping () -> Void, onCancel: (() -> Void)? = nil) {
        guard !isSaving, !isNavigationPending else {
            onCancel?()
            return
        }
        watches.requestNavigation(
            {
                self.calibers.requestNavigation(
                    { self.jobs.requestNavigation(action, onCancel: onCancel) }, onCancel: onCancel)
            }, onCancel: onCancel)
    }

    func stay() {
        if watches.isNavigationPending {
            watches.stay()
        } else if calibers.isNavigationPending {
            calibers.stay()
        } else {
            jobs.stay()
        }
    }

    func discardAndContinue() {
        if watches.isNavigationPending {
            watches.discardAndContinue()
        } else if calibers.isNavigationPending {
            calibers.discardAndContinue()
        } else {
            jobs.discardAndContinue()
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
        } else {
            await jobs.saveAndContinue()
        }
    }
}
