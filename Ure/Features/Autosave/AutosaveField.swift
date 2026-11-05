import Foundation
import Observation

// One text field that saves as you type. A change saves after a pause in typing, when focus
// leaves, and when the app asks for every field to save. Each burst of typing is one Undo step,
// and Undo and Redo save again. Esc puts back the text the field had when focus entered it.
// A text the field does not accept, such as a blank title or a number it cannot read, stays on
// screen but never saves, so the record keeps the last text it accepted. Undo never offers it back.
@Observable
final class AutosaveField {
    static let typingPause: Duration = .milliseconds(500)

    private(set) var text: String
    private(set) var savedText: String
    private(set) var isEditing = false
    private(set) var isSaving = false
    private(set) var saveError: String?
    @ObservationIgnored private let actionName: String
    @ObservationIgnored private let save: (String) async throws -> Void
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    @ObservationIgnored private let accepts: (String) -> Bool
    @ObservationIgnored private var scheduledSave: Task<Void, Never>?
    @ObservationIgnored private var runningSave: Task<Bool, Never>?
    @ObservationIgnored private var textBeforeEditing: String?
    @ObservationIgnored private var textBeforeChange: String?
    @ObservationIgnored private weak var undoManager: UndoManager?

    init(
        text: String, actionName: String, save: @escaping (String) async throws -> Void,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        accepts: @escaping (String) -> Bool = { _ in true }
    ) {
        self.text = text
        savedText = text
        self.actionName = actionName
        self.save = save
        self.pause = pause
        self.accepts = accepts
    }

    var hasUnsavedChanges: Bool { text != savedText || isSaving }

    func beginEditing() {
        isEditing = true
        textBeforeEditing = text
        textBeforeChange = nil
    }

    func endEditing() {
        isEditing = false
        textBeforeEditing = nil
        textBeforeChange = nil
        saveNow()
    }

    func change(to newText: String, undoManager: UndoManager?) {
        guard newText != text else { return }
        if textBeforeChange == nil {
            textBeforeChange = text
            registerUndo(restoring: text, with: undoManager)
        }
        text = newText
        scheduleSave()
    }

    func revert(undoManager: UndoManager?) {
        guard let textBeforeEditing, textBeforeEditing != text else { return }
        textBeforeChange = nil
        change(to: textBeforeEditing, undoManager: undoManager)
        textBeforeChange = nil
        saveNow()
    }

    // Adopts a stored value when nothing typed here is waiting to save.
    func refresh(_ stored: String) {
        guard !isEditing, !hasUnsavedChanges, saveError == nil else { return }
        text = stored
        savedText = stored
    }

    func saveNow() {
        scheduledSave?.cancel()
        scheduledSave = nil
        Task { await flush() }
    }

    @discardableResult
    func flush() async -> Bool {
        scheduledSave?.cancel()
        scheduledSave = nil
        while true {
            while let runningSave { _ = await runningSave.value }
            guard text != savedText else {
                saveError = nil
                return true
            }
            guard accepts(text) else { return false }
            let value = text
            let task = Task {
                let succeeded = await write(value)
                runningSave = nil
                return succeeded
            }
            runningSave = task
            guard await task.value else { return false }
        }
    }

    func discardUndo() {
        undoManager?.removeAllActions(withTarget: self)
    }

    private func write(_ value: String) async -> Bool {
        isSaving = true
        defer { isSaving = false }
        do {
            try await save(value)
            savedText = value
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    private func scheduleSave() {
        scheduledSave?.cancel()
        scheduledSave = Task { [weak self, pause] in
            do { try await pause(Self.typingPause) } catch { return }
            guard !Task.isCancelled, let self else { return }
            scheduledSave = nil
            textBeforeChange = nil
            await flush()
        }
    }

    private func registerUndo(restoring value: String, with undoManager: UndoManager?) {
        guard let undoManager, accepts(value) else { return }
        self.undoManager = undoManager
        undoManager.registerUndo(withTarget: self) { [weak undoManager] field in
            MainActor.assumeIsolated {
                field.restore(value, undoManager: undoManager)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func restore(_ value: String, undoManager: UndoManager?) {
        textBeforeChange = nil
        registerUndo(restoring: text, with: undoManager)
        text = value
        saveNow()
    }
}
