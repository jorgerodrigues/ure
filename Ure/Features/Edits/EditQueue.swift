import Foundation
import Observation

// Where an edit's failure shows, and which part of the app waits while the edit saves.
nonisolated enum EditScope: Hashable, Sendable {
    case calibers
    case watches
    case jobs
    case parts
    case notes(LibraryItemOwner)
    case checklist(UUID)
    case material(LibraryItemOwner)

    var isMaterial: Bool {
        if case .material = self { return true }
        return false
    }
}

// One thing you do that Undo takes back in one step, such as a burst of typing in a field or a
// click on a part's state. Its number is all the undo manager keeps.
nonisolated struct EditChange: Hashable, Sendable {
    let id: Int
}

// What happened to a submitted edit.
enum EditResult {
    case saved(EditApplied)
    case failed(any Error)

    var isSaved: Bool {
        if case .saved = self { return true }
        return false
    }

    var changes: [LibraryChange] {
        if case .saved(let applied) = self { return applied.changes }
        return []
    }

    var error: (any Error)? {
        if case .failed(let error) = self { return error }
        return nil
    }
}

// The field or checklist that made a change. Undo and Redo go to it first.
struct UndoOwner {
    // Puts the change back on screen itself, at once, and saves that through the queue under
    // the way back's number.
    let undo: (_ undone: EditChange, _ back: EditChange) -> UndoHandling
    // Forgets what it kept for a step the undo manager no longer holds.
    let forget: (EditChange) -> Void
}

// What the owner of a change did when Undo or Redo reached it.
enum UndoHandling {
    // It has nothing for the change, so the stored inverse undoes it.
    case notMine
    // It put the change back. There is no Redo of text the field does not take.
    case done(canRedo: Bool)
}

// An edit the queue did not apply, because what it needs did not hold when its turn came, such
// as a fact on the record that is not valid yet.
nonisolated struct EditRefusal: LocalizedError, Equatable {
    let message: String

    var errorDescription: String? { message }
}

// An edit that was dropped with every change that did not save.
nonisolated struct EditDiscarded: Error {}

// A check that runs when an edit's turn comes, after every edit before it. A message from it
// refuses the edit, such as when a fact on the record is not valid yet.
struct EditCheck {
    let refusal: () -> String?
}

// How saving everything ended, before quitting, closing the window, restoring or exporting.
enum SaveOutcome: Equatable {
    case saved
    // A field shows text it does not take, such as a blank name, so that text can't save.
    case textNotValid
    // An edit failed, and the queue waits for Try Again or for the changes to be discarded.
    case stopped
}

// One submitted edit. Its result comes once the queue has applied it, after every edit submitted
// before it.
@Observable
final class EditTicket {
    // The Undo step the edit belongs to, if it has one.
    let change: EditChange?
    private(set) var result: EditResult?
    @ObservationIgnored private var waiters: [CheckedContinuation<EditResult, Never>] = []

    init(change: EditChange?) {
        self.change = change
    }

    var isPending: Bool { result == nil }

    // The result, once the edit has run.
    var value: EditResult {
        get async {
            if let result { return result }
            return await withCheckedContinuation { waiters.append($0) }
        }
    }

    var saved: Bool {
        get async { await value.isSaved }
    }

    fileprivate func finish(_ result: EditResult) {
        self.result = result
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume(returning: result) }
    }
}

// Typing on screen that has not reached the queue: a field or a checklist. The queue asks it to
// submit before any other edit, so edits save in the order you made them, and asks it to save
// everything before quitting, closing the window, restoring and exporting a backup.
struct TypingSource {
    // When the typing waiting to submit began, so typing submits in the order it began. Nil when
    // nothing waits to submit.
    let began: () -> EditChange?
    // Submits typing that can save, as the typing pause would.
    let submit: () -> Void
    // Submits everything it can before quitting.
    let saveAll: () -> Void
    // Whether text on screen has not reached the queue.
    let isUnsaved: () -> Bool
    // Drops the typing on screen and shows what the library holds.
    let discard: () -> Void
}

// The one queue every change to the library goes through, in the order you made the changes. It
// applies one edit at a time, so each edit runs on a library that holds every edit before it.
// Each applied edit reads the rows it changes and gives back the edit that undoes it, and the
// queue keeps that inverse under the change's number. When an edit fails, the queue stops there:
// nothing runs past it until Try Again runs it again, or until the changes that did not save are
// discarded. Changes made meanwhile show on screen and wait in order. Undo and Redo register on
// the window's undo manager with the queue as their target and the change's number as their
// value, at the moment you act, so ⌘Z always follows the order you acted in. Undo submits the
// inverse as a new edit, which waits like any other.
@Observable
final class EditQueue {
    let coordinator: LibraryCoordinator
    // Why the queue stopped: the error of the edit that failed. Nil while edits run.
    private(set) var failure: String?
    // A rule that a change broke when you made it, such as a second open job for a watch, in
    // the scope where it shows, until the next change there.
    private(set) var refusals: [EditScope: String] = [:]
    private var pending: [QueuedEdit] = []
    private var typing: [ObjectIdentifier: TypingSource] = [:]
    @ObservationIgnored private let editor: LibraryEditor
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var running:
        (ticket: EditTicket, task: Task<EditApplied, any Error>)?
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var listeners: [(LibraryChange, Bool) -> Void] = []
    @ObservationIgnored private var lastChange = 0
    // The edit that undoes each change, once the change has saved.
    @ObservationIgnored private var inverses: [EditChange: LibraryEdit] = [:]
    // The field or checklist that made a change. Its Undo and Redo go to it first: it puts back
    // the text at once and saves it in order, under the way back's number. When it is gone, the
    // stored inverse undoes the change instead.
    @ObservationIgnored private var owners: [EditChange: UndoOwner] = [:]
    // The ways back on each undo manager's Redo list. A new action clears that list, and then
    // the queue and the owners forget what they kept for them.
    @ObservationIgnored private var redoChanges: [ObjectIdentifier: Set<EditChange>] = [:]
    // Steps that Undo used up or the undo manager dropped while their edit still waited. The
    // queue keeps no inverse for them once the edit has run.
    @ObservationIgnored private var retired: Set<EditChange> = []
    @ObservationIgnored private var isSubmittingTyping = false
    @ObservationIgnored private let undoManagers = NSHashTable<UndoManager>.weakObjects()
    @ObservationIgnored private var localTyping: [UUID: LocalTyping] = [:]

    init(coordinator: LibraryCoordinator) {
        self.coordinator = coordinator
        editor = LibraryEditor(coordinator: coordinator)
    }

    // MARK: State

    // Nothing is waiting to save.
    var isIdle: Bool { pending.isEmpty }

    // An edit failed, and the edits after it wait.
    var isStopped: Bool { failure != nil }

    // A change you made, other than typing, is still saving. Lists and record buttons wait.
    var isBusy: Bool { pending.contains(where: \.holdsScreen) }

    func isBusy(_ scope: EditScope) -> Bool {
        pending.contains { $0.holdsScreen && $0.scope == scope }
    }

    var isBusyWithMaterial: Bool { pending.contains { $0.holdsScreen && $0.scope.isMaterial } }

    func refusal(in scope: EditScope) -> String? { refusals[scope] }

    // Says why a change could not be made, where the change was made.
    func report(_ message: String, in scope: EditScope) { refusals[scope] = message }

    func clearRefusal(in scope: EditScope) { refusals[scope] = nil }

    // How many Undo and Redo steps the queue keeps an inverse or an owner for.
    var keptUndoCount: Int { Set(inverses.keys).union(owners.keys).count }

    // Text on screen that has not reached the queue: typing, and text the field does not take
    // yet.
    var hasUnsavedTyping: Bool { typing.values.contains { $0.isUnsaved() } }

    // Hears what the library holds after each edit. The flag says whether Undo or Redo made it.
    func listen(_ listener: @escaping (LibraryChange, Bool) -> Void) {
        listeners.append(listener)
    }

    // MARK: Stopped

    // Try Again: the edit that failed runs once more, and then every edit that waits, in order.
    // If it fails again, the queue stays stopped.
    func retry() {
        guard failure != nil else { return }
        failure = nil
        startWorker()
    }

    // Drops the edit that failed and every edit that waits, with the typing on screen. Each
    // dropped edit ends as discarded, so its field or checklist shows what the library holds.
    // The Undo and Redo lists start over, as after Revert to Saved, because their steps may
    // belong to dropped edits.
    func discardUnsaved() {
        guard failure != nil else { return }
        let dropped = pending
        pending = []
        failure = nil
        for source in typing.values { source.discard() }
        let result = EditResult.failed(EditDiscarded())
        for item in dropped {
            item.ticket.finish(result)
            item.then?(result)
        }
        discardUndo()
        resumeIdleWaiters()
    }

    // MARK: Submitting

    // Submits an edit you made now, after the typing on screen. With an undo manager and an
    // action name, ⌘Z undoes it, registered now. A precondition runs when the edit's turn comes;
    // a message from it refuses the edit and stops the queue. The edit holds the screen while
    // it saves.
    @discardableResult
    func submit(
        _ edit: LibraryEdit, in scope: EditScope, undo actionName: String? = nil,
        undoManager: UndoManager? = nil, requires: EditCheck? = nil,
        then: ((EditResult) -> Void)? = nil
    ) -> EditTicket {
        flushTyping()
        var change: EditChange?
        if let actionName, let undoManager {
            let step = EditUndoStep(
                change: makeChange(), actionName: actionName, scope: scope, holdsScreen: true)
            register(step, on: undoManager)
            change = step.change
        }
        refusals[scope] = nil
        return enqueue(
            QueuedEdit(
                work: .edit(edit), change: change, scope: scope, holdsScreen: true,
                isUndo: false, requires: requires, then: then))
    }

    // Registers one Undo step, now, for a change that its owner shows at once and saves itself,
    // such as a burst of typing, whose edit comes once the typing pauses, or a checklist's tick.
    // Its Undo and Redo go to the owner first.
    func registerStep(
        _ actionName: String, in scope: EditScope, undoManager: UndoManager?,
        owner: UndoOwner
    ) -> EditChange? {
        guard let undoManager else { return nil }
        let step = EditUndoStep(
            change: makeChange(), actionName: actionName, scope: scope, holdsScreen: false)
        register(step, on: undoManager)
        owners[step.change] = owner
        return step.change
    }

    // Submits what an owner shows, such as typing, as an edit of its step. It does not hold the
    // screen.
    @discardableResult
    func submitTyping(
        _ edit: LibraryEdit, in scope: EditScope, as change: EditChange?,
        then: @escaping (EditResult) -> Void
    ) -> EditTicket {
        flushTyping()
        return enqueue(
            QueuedEdit(
                work: .edit(edit), change: change, scope: scope, holdsScreen: false,
                isUndo: false, requires: nil, then: then))
    }

    // Stops an edit before it runs, or while it runs if it can stop, such as an import. A
    // stopped edit is not a failure, so the edits after it still run.
    func cancel(_ ticket: EditTicket) {
        if let running, running.ticket === ticket {
            running.task.cancel()
        } else if let index = pending.firstIndex(where: { $0.ticket === ticket }) {
            let item = pending.remove(at: index)
            let result = EditResult.failed(CancellationError())
            item.ticket.finish(result)
            item.then?(result)
            if pending.isEmpty { resumeIdleWaiters() }
        }
    }

    // MARK: Typing

    func track(_ key: ObjectIdentifier, _ source: TypingSource) { typing[key] = source }

    func untrack(_ key: ObjectIdentifier) {
        if typing[key] != nil { typing[key] = nil }
    }

    // Asks every field with typing to submit it, in the order the typing began, as any other
    // edit does first.
    func flushTyping() {
        guard !isSubmittingTyping else { return }
        isSubmittingTyping = true
        defer { isSubmittingTyping = false }
        for source in sources() { source.submit() }
    }

    // The typing sources, those whose typing began first before the others.
    private func sources() -> [TypingSource] {
        Array(typing.values).sorted { lhs, rhs in
            (lhs.began()?.id ?? Int.max) < (rhs.began()?.id ?? Int.max)
        }
    }

    // MARK: Waiting

    // Waits until every edit submitted so far, and every edit they led to, has run, or until
    // the queue stops at a failure.
    func waitUntilIdle() async {
        guard !pending.isEmpty, failure == nil else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // The one wait before quitting, closing the window, restoring and exporting a backup. Every
    // field saves what it can, and the queue runs until nothing waits or an edit fails. Typing
    // done during the wait saves too, so only text a field does not take is left.
    func saveEverything() async -> SaveOutcome {
        while true {
            isSubmittingTyping = true
            for source in sources() { source.saveAll() }
            isSubmittingTyping = false
            guard failure == nil, !pending.isEmpty else { break }
            await waitUntilIdle()
        }
        if failure != nil { return .stopped }
        return hasUnsavedTyping ? .textNotValid : .saved
    }

    private func resumeIdleWaiters() {
        let waiting = idleWaiters
        idleWaiters = []
        for waiter in waiting { waiter.resume() }
    }

    // MARK: Undo

    // Forgets every Undo step, such as before a restore replaces the library. Every Undo step of
    // the window comes from the queue, so the whole list goes, with the groups the steps were in.
    func discardUndo() {
        for undoManager in undoManagers.allObjects { undoManager.removeAllActions() }
        for (change, owner) in owners { owner.forget(change) }
        inverses = [:]
        owners = [:]
        redoChanges = [:]
        retired = Set(pending.compactMap(\.change))
    }

    // Lets go of a step's inverse, also the one its waiting edit would give.
    private func retire(_ change: EditChange) {
        inverses[change] = nil
        if pending.contains(where: { $0.change == change }) { retired.insert(change) }
    }

    // A step the undo manager no longer holds needs nothing kept for it.
    private func forget(_ change: EditChange) {
        retire(change)
        owners.removeValue(forKey: change)?.forget(change)
    }

    // Keeps track of the Redo list as AppKit does: a step registered while undoing goes onto it,
    // and a step registered for a new action clears it.
    private func noteRegistration(_ change: EditChange, on undoManager: UndoManager) {
        let key = ObjectIdentifier(undoManager)
        if undoManager.isUndoing {
            redoChanges[key, default: []].insert(change)
        } else if !undoManager.isRedoing {
            for dropped in redoChanges.removeValue(forKey: key) ?? [] { forget(dropped) }
        }
    }

    private func register(_ step: EditUndoStep, on undoManager: UndoManager) {
        noteRegistration(step.change, on: undoManager)
        undoManagers.add(undoManager)
        undoManager.registerUndo(withTarget: self) { [weak undoManager] queue in
            MainActor.assumeIsolated { queue.reverse(step, undoManager: undoManager) }
        }
        undoManager.setActionName(step.actionName)
    }

    // Undo and Redo. The way back registers now, under a new change. The change's owner puts back
    // its text at once and submits it under that number, so typing that follows builds on it.
    // Without an owner, the rest of the typing submits, and then the inverse, which is read once
    // the change itself has run.
    private func reverse(_ step: EditUndoStep, undoManager: UndoManager?) {
        if let undoManager, undoManager.isRedoing {
            redoChanges[ObjectIdentifier(undoManager)]?.remove(step.change)
        }
        let back = EditUndoStep(
            change: makeChange(), actionName: step.actionName, scope: step.scope,
            holdsScreen: step.holdsScreen)
        refusals[step.scope] = nil
        if let owner = owners[step.change],
            case .done(let canRedo) = owner.undo(step.change, back.change)
        {
            retire(step.change)
            owners[step.change] = nil
            if canRedo, let undoManager {
                register(back, on: undoManager)
                owners[back.change] = owner
            } else {
                owner.forget(back.change)
            }
            return
        }
        if let undoManager { register(back, on: undoManager) }
        flushTyping()
        enqueue(
            QueuedEdit(
                work: .reverse(step.change), change: back.change, scope: step.scope,
                holdsScreen: step.holdsScreen, isUndo: true, requires: nil, then: nil))
    }

    // MARK: Typing that saves nowhere

    // A burst of typing that stays on screen until you submit it, such as a part's name on its
    // job's add line, as one Undo step. The undo manager keeps the texts to put back, and the
    // step goes when the typing is submitted or emptied. The handler puts back texts and gives
    // the ones it had, for Redo.
    func registerLocalTyping(
        _ key: UUID, restoring texts: [String], actionName: String, undoManager: UndoManager,
        restore: @escaping ([String]) -> [String]
    ) {
        let target = localTyping[key] ?? LocalTyping()
        localTyping[key] = target
        target.restore = restore
        if !undoManager.isUndoing, !undoManager.isRedoing {
            for dropped in redoChanges.removeValue(forKey: ObjectIdentifier(undoManager)) ?? [] {
                forget(dropped)
            }
        }
        undoManagers.add(undoManager)
        Self.registerLocal(texts, actionName: actionName, on: target, undoManager)
    }

    func removeLocalTyping(_ key: UUID) {
        guard let target = localTyping[key] else { return }
        for undoManager in undoManagers.allObjects {
            undoManager.removeAllActions(withTarget: target)
        }
    }

    private static func registerLocal(
        _ texts: [String], actionName: String, on target: LocalTyping, _ undoManager: UndoManager
    ) {
        undoManager.registerUndo(withTarget: target) { [weak undoManager] target in
            MainActor.assumeIsolated {
                guard let undoManager, let restore = target.restore else { return }
                registerLocal(restore(texts), actionName: actionName, on: target, undoManager)
            }
        }
        undoManager.setActionName(actionName)
    }

    // MARK: Running

    private func makeChange() -> EditChange {
        lastChange += 1
        return EditChange(id: lastChange)
    }

    @discardableResult
    private func enqueue(_ item: QueuedEdit) -> EditTicket {
        pending.append(item)
        startWorker()
        return item.ticket
    }

    private func startWorker() {
        if worker == nil, failure == nil { worker = Task { await drain() } }
    }

    // Runs the edits in order. A failure stops the queue with the failed edit still first, so
    // Try Again runs it again. An edit that you stopped, such as an import, is not a failure.
    private func drain() async {
        while failure == nil, let item = pending.first {
            let result = await run(item)
            if let error = result.error, !(error is CancellationError) {
                failure = error.localizedDescription
                break
            }
            pending.removeFirst()
            finish(item, with: result)
        }
        worker = nil
        resumeIdleWaiters()
    }

    private func run(_ item: QueuedEdit) async -> EditResult {
        if let message = item.requires?.refusal() {
            return .failed(EditRefusal(message: message))
        }
        let edit: LibraryEdit
        switch item.work {
        case .edit(let submitted):
            edit = submitted
        case .reverse(let change):
            guard let inverse = inverses[change] else { return .saved(EditApplied()) }
            edit = inverse
        }
        let editor = editor
        let task = Task { try await editor.apply(edit) }
        running = (item.ticket, task)
        defer { running = nil }
        do {
            return .saved(try await task.value)
        } catch {
            return .failed(error)
        }
    }

    // What the library holds now reaches the screens first, then the edit's own handler. An Undo
    // uses up the inverse it applied.
    private func finish(_ item: QueuedEdit, with result: EditResult) {
        if case .saved(let applied) = result {
            if case .reverse(let undone) = item.work {
                inverses[undone] = nil
                owners.removeValue(forKey: undone)?.forget(undone)
            }
            if let change = item.change, !retired.contains(change), let inverse = applied.inverse {
                inverses[change] = inverse
            }
            for change in applied.changes {
                for listener in listeners { listener(change, item.isUndo) }
            }
        }
        if let change = item.change, !pending.contains(where: { $0.change == change }) {
            retired.remove(change)
        }
        item.ticket.finish(result)
        item.then?(result)
    }
}

// The value the undo manager keeps for one Undo or Redo step.
private nonisolated struct EditUndoStep: Sendable {
    let change: EditChange
    let actionName: String
    let scope: EditScope
    let holdsScreen: Bool
}

private struct QueuedEdit {
    enum Work {
        case edit(LibraryEdit)
        // The inverse of a change, read when its turn comes.
        case reverse(EditChange)
    }

    let work: Work
    let change: EditChange?
    let scope: EditScope
    let holdsScreen: Bool
    let isUndo: Bool
    let requires: EditCheck?
    let then: ((EditResult) -> Void)?
    let ticket: EditTicket

    init(
        work: Work, change: EditChange?, scope: EditScope, holdsScreen: Bool, isUndo: Bool,
        requires: EditCheck?, then: ((EditResult) -> Void)?
    ) {
        self.work = work
        self.change = change
        self.scope = scope
        self.holdsScreen = holdsScreen
        self.isUndo = isUndo
        self.requires = requires
        self.then = then
        ticket = EditTicket(change: change)
    }
}

// The target of the Undo steps of one line's typing that saves nowhere. The queue keeps it, so
// the target lives as long as the library is open.
private final class LocalTyping {
    var restore: (([String]) -> [String])?
}
