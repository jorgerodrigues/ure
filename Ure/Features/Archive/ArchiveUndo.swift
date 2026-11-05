import Foundation

// Archives and unarchives a record one change at a time, with Undo and Redo. Undo sets the
// record back, Redo sets it again, and both keep the name of what you did, such as
// "Archive Watch". A write says whether the record now has the state it was given.
final class ArchiveUndo {
    typealias Write = (_ archived: Bool) async -> Bool

    private var change: Task<Bool, Never>?
    private weak var undoManager: UndoManager?

    // Runs the write after any change that is still saving.
    func perform(_ archived: Bool, write: @escaping Write) async -> Bool {
        await enqueue(archived, write: write).value
    }

    func registerUndo(
        setting archived: Bool, actionName: String, undoManager: UndoManager?,
        write: @escaping Write
    ) {
        guard let undoManager else { return }
        self.undoManager = undoManager
        undoManager.registerUndo(withTarget: self) { [weak undoManager] archiving in
            MainActor.assumeIsolated {
                archiving.registerUndo(
                    setting: !archived, actionName: actionName, undoManager: undoManager,
                    write: write)
                archiving.enqueue(archived, write: write)
            }
        }
        undoManager.setActionName(actionName)
    }

    // Starts the write at once, so a wait that follows sees it.
    @discardableResult
    private func enqueue(_ archived: Bool, write: @escaping Write) -> Task<Bool, Never> {
        let previous = change
        let next = Task { () -> Bool in
            _ = await previous?.value
            return await write(archived)
        }
        change = next
        return next
    }

    // Waits for a change that Undo or Redo started.
    func wait() async { _ = await change?.value }

    func discardUndo() { undoManager?.removeAllActions(withTarget: self) }
}
