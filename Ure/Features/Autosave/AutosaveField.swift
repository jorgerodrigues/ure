import Foundation
import Observation

// One text field that saves as you type. The field only holds the typing: its text goes to the
// library's edit queue as an edit after a pause in typing, when focus leaves, before any other
// edit, and when the app asks every field to save. Each burst of typing is one Undo step, which
// the queue keeps and undoes from the stored data. Esc puts back the text the field had when
// focus entered it. A text the field does not accept, such as a blank title or a number it
// cannot read, stays on screen but never saves, so the record keeps the last text it accepted.
@Observable
final class AutosaveField {
    static let typingPause: Duration = .milliseconds(500)

    private(set) var text: String
    // What the library holds, or will hold once this field's edits have run.
    private(set) var savedText: String
    private(set) var isEditing = false
    // An edit of this field is still waiting in the queue.
    private(set) var isSaving = false
    private(set) var saveError: String?
    @ObservationIgnored private let actionName: String
    @ObservationIgnored private let queue: EditQueue
    @ObservationIgnored private let scope: EditScope
    @ObservationIgnored private let edit: (String) throws -> LibraryEdit
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    @ObservationIgnored private let accepts: (String) -> Bool
    @ObservationIgnored private let normalized: (String) -> String
    // Saving everything, such as before quitting, puts back the stored text in place of text the
    // field does not take, such as a blank material title, instead of keeping it as unsaved.
    @ObservationIgnored private let putsBackRefusedText: Bool
    @ObservationIgnored private var scheduledSubmit: Task<Void, Never>?
    @ObservationIgnored private var textBeforeEditing: String?
    // A burst of typing is going on. It ends when its text submits.
    @ObservationIgnored private var isTyping = false
    // The Undo step that the text on screen belongs to while it has not saved.
    @ObservationIgnored private var unsavedChange: EditChange?
    // What the library holds, as far as this field knows.
    @ObservationIgnored private var storedText: String
    @ObservationIgnored private var latest: EditTicket?
    @ObservationIgnored private var isTracked = false

    init(
        text: String, actionName: String, queue: EditQueue, scope: EditScope,
        edit: @escaping (String) throws -> LibraryEdit,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        accepts: @escaping (String) -> Bool = { _ in true },
        normalized: @escaping (String) -> String = { $0 }, putsBackRefusedText: Bool = false
    ) {
        self.text = text
        savedText = text
        storedText = text
        self.actionName = actionName
        self.queue = queue
        self.scope = scope
        self.edit = edit
        self.pause = pause
        self.accepts = accepts
        self.normalized = normalized
        self.putsBackRefusedText = putsBackRefusedText
    }

    // Text on screen that has not saved, or an edit of it still waiting.
    var hasUnsavedChanges: Bool { text != savedText || isSaving }

    // Text on screen that the library does not hold and no edit will give it: typing that has
    // not submitted, text the field does not take, and text whose save failed.
    var hasUnsavedText: Bool { text != savedText }

    // Text the field does not take, such as a blank name. It never saves.
    var isRefused: Bool { text != savedText && !accepts(text) }

    // Text whose save failed. Try Again, or a change that needs the record saved, tries it once
    // more.
    var hasFailedText: Bool { text != savedText && saveError != nil }

    func saveFailedText() {
        if hasFailedText { saveNow() }
    }

    func beginEditing() {
        isEditing = true
        textBeforeEditing = text
    }

    func endEditing() {
        isEditing = false
        textBeforeEditing = nil
        saveNow()
        showSavedText()
    }

    func change(to newText: String, undoManager: UndoManager?) {
        guard newText != text else { return }
        if !isTyping {
            isTyping = true
            if unsavedChange == nil {
                unsavedChange = queue.beginTyping(
                    actionName, in: scope, undoManager: undoManager
                ) { [weak self] change in self?.undoReachedTyping(change) }
            }
        }
        text = newText
        track()
        scheduleSubmit()
    }

    // Esc puts back the text from when focus entered the field. The typing before it submits
    // first, so Esc is an Undo step of its own and ⌘Z brings the typing back.
    func revert(undoManager: UndoManager?) {
        guard let textBeforeEditing, textBeforeEditing != text else { return }
        if isTyping { saveNow() }
        change(to: textBeforeEditing, undoManager: undoManager)
        saveNow()
    }

    // Adopts a stored value when nothing typed here is waiting. After Undo and Redo it does so
    // also while the field has the cursor, because Undo is what changed it.
    func refresh(_ stored: String, force: Bool = false) {
        guard force || !isEditing, !isTyping, !isSaving, text == savedText, saveError == nil
        else { return }
        text = stored
        savedText = stored
        storedText = stored
    }

    // Submits the text now, if it changed and the field takes it. Try Again calls it too.
    func saveNow() {
        scheduledSubmit?.cancel()
        scheduledSubmit = nil
        isTyping = false
        defer { track() }
        guard text != savedText else {
            settle()
            return
        }
        guard accepts(text) else { return }
        let value = text
        let submitted: LibraryEdit
        do {
            submitted = try edit(value)
        } catch {
            saveError = error.localizedDescription
            return
        }
        let change = unsavedChange
        unsavedChange = nil
        savedText = value
        isSaving = true
        latest = queue.submitTyping(submitted, in: scope, as: change) { [weak self] result in
            self?.finished(value, change: change, result: result)
        }
    }

    // The field goes, such as with its part, and its text no longer counts as unsaved.
    func discard() {
        scheduledSubmit?.cancel()
        scheduledSubmit = nil
        isTyping = false
        if let unsavedChange { queue.typingSettled(unsavedChange) }
        unsavedChange = nil
        text = savedText
        track()
    }

    private func finished(_ value: String, change: EditChange?, result: EditResult) {
        if latest?.isPending != true { isSaving = false }
        switch result {
        case .saved:
            storedText = value
            if savedText == value { saveError = nil }
            if let change { queue.typingSettled(change) }
            showSavedText()
        case .failed(let error):
            // Only the latest save's failure keeps its text on screen as not saved. An older one
            // that a later save took over settles.
            if savedText == value {
                saveError = error.localizedDescription
                savedText = storedText
                if unsavedChange == nil { unsavedChange = change }
            } else if let change {
                queue.typingSettled(change)
            }
        }
        track()
    }

    // Once saved, a field without the cursor shows its text the way it shows a stored value,
    // such as "28.800 vph" for "28800vph".
    private func showSavedText() {
        guard !isEditing, !isTyping, !isSaving, text == savedText, saveError == nil else {
            return
        }
        let shown = normalized(text)
        guard shown != text else { return }
        text = shown
        savedText = shown
        storedText = shown
    }

    // Undo reached this field's typing while it was still on screen. Text that can save submits
    // first, so the Undo that follows takes it back from the library. Text that can't goes back
    // to the stored text, as nothing of it saved.
    private func undoReachedTyping(_ change: EditChange) {
        guard unsavedChange == change else { return }
        if isTyping, text != savedText, accepts(text), saveError == nil {
            saveNow()
            return
        }
        guard text != savedText else { return }
        putBackSavedText()
    }

    private func putBackSavedText() {
        scheduledSubmit?.cancel()
        scheduledSubmit = nil
        isTyping = false
        if let unsavedChange { queue.typingSettled(unsavedChange) }
        unsavedChange = nil
        saveError = nil
        text = savedText
        track()
    }

    private func saveEverything() {
        if putsBackRefusedText, isRefused { putBackSavedText() }
        saveNow()
    }

    private func settle() {
        guard let unsavedChange else { return }
        queue.typingSettled(unsavedChange)
        self.unsavedChange = nil
    }

    private func scheduleSubmit() {
        scheduledSubmit?.cancel()
        scheduledSubmit = Task { [weak self, pause] in
            do { try await pause(Self.typingPause) } catch { return }
            guard !Task.isCancelled, let self else { return }
            scheduledSubmit = nil
            saveNow()
        }
    }

    // The queue asks the field to submit before other edits, and before quitting.
    private func track() {
        let unsaved = text != savedText || isTyping
        guard unsaved != isTracked else { return }
        isTracked = unsaved
        let key = ObjectIdentifier(self)
        guard unsaved else {
            queue.untrack(key)
            return
        }
        queue.track(
            key,
            TypingSource(
                began: { [weak self] in
                    guard let self, isTyping else { return nil }
                    return unsavedChange
                },
                submit: { [weak self] in
                    guard let self, isTyping else { return }
                    saveNow()
                },
                saveAll: { [weak self] in self?.saveEverything() },
                isUnsaved: { [weak self] in self?.hasUnsavedText ?? false }))
    }
}
