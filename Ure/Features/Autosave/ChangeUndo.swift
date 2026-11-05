import Foundation

// Makes one kind of change to a record one change at a time, with Undo and Redo, such as an
// archive or a job's state. Undo sets the value the record had, Redo sets the value it was
// given, and both keep the name of what you did, such as "Archive Watch". A write says whether
// the record now has the value it was given.
final class ChangeUndo<Value> {
    typealias Write = (_ value: Value) async -> Bool

    private var change: Task<Bool, Never>?
    private weak var undoManager: UndoManager?

    // Runs the write after any change that is still saving.
    func perform(_ value: Value, write: @escaping Write) async -> Bool {
        await enqueue(value, write: write).value
    }

    // Registers an Undo that sets the record back to a value, and a Redo that sets it to the
    // value it has now.
    func registerUndo(
        setting value: Value, redoing redo: Value, actionName: String,
        undoManager: UndoManager?, write: @escaping Write
    ) {
        guard let undoManager else { return }
        self.undoManager = undoManager
        undoManager.registerUndo(withTarget: self) { [weak undoManager] changes in
            MainActor.assumeIsolated {
                changes.registerUndo(
                    setting: redo, redoing: value, actionName: actionName,
                    undoManager: undoManager, write: write)
                changes.enqueue(value, write: write)
            }
        }
        undoManager.setActionName(actionName)
    }

    // Starts the write at once, so a wait that follows sees it.
    @discardableResult
    private func enqueue(_ value: Value, write: @escaping Write) -> Task<Bool, Never> {
        let previous = change
        let next = Task { () -> Bool in
            _ = await previous?.value
            return await write(value)
        }
        change = next
        return next
    }

    // Waits for a change that Undo or Redo started.
    func wait() async { _ = await change?.value }

    func discardUndo() { undoManager?.removeAllActions(withTarget: self) }
}
