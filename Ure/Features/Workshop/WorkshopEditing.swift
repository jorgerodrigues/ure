import Observation

@Observable
final class WorkshopEditing {
    let watches: WatchState
    let calibers: CaliberState

    init(watches: WatchState, calibers: CaliberState) {
        self.watches = watches
        self.calibers = calibers
    }

    var isSaving: Bool { watches.isSaving || calibers.isSaving }
    var hasUnsavedChanges: Bool { watches.hasUnsavedChanges || calibers.hasUnsavedChanges }
    var isNavigationPending: Bool { watches.isNavigationPending || calibers.isNavigationPending }

    var showsUnsavedChanges: Bool {
        get { watches.showsUnsavedChanges || calibers.showsUnsavedChanges }
        set {
            if watches.isNavigationPending {
                watches.showsUnsavedChanges = newValue
            } else {
                calibers.showsUnsavedChanges = newValue
            }
        }
    }

    var unsavedChangesTitle: String {
        if watches.isNavigationPending { return "Save changes to this watch?" }
        return "Save changes to this caliber?"
    }

    func requestNavigation(_ action: @escaping () -> Void, onCancel: (() -> Void)? = nil) {
        guard !isSaving, !isNavigationPending else {
            onCancel?()
            return
        }
        watches.requestNavigation(
            { self.calibers.requestNavigation(action, onCancel: onCancel) }, onCancel: onCancel)
    }

    func stay() {
        if watches.isNavigationPending { watches.stay() } else { calibers.stay() }
    }

    func discardAndContinue() {
        if watches.isNavigationPending {
            watches.discardAndContinue()
        } else {
            calibers.discardAndContinue()
        }
    }

    func saveAndContinueCommand() {
        Task { await saveAndContinue() }
    }

    func saveAndContinue() async {
        if watches.isNavigationPending {
            await watches.saveAndContinue()
        } else {
            await calibers.saveAndContinue()
        }
    }
}
