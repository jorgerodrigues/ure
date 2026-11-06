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
    // Puts the change back itself, at once, and saves it under the way back's number.
    let undo: (_ undone: EditChange, _ back: EditChange) -> UndoHandling
    // Forgets what it kept for a step the undo manager no longer holds.
    let forget: (EditChange) -> Void
}

// What the owner of a change did when Undo or Redo reached it.
enum UndoHandling {
    // It has nothing for the change, so the stored inverse undoes it.
    case notMine
    // It put the change back. Redo can bring it again only when the owner kept something for
    // it, which it does not for text the field does not take.
    case done(canRedo: Bool)
}

// An edit the queue did not apply, because what it needs did not hold when its turn came, such
// as a field on the record that did not save.
nonisolated struct EditRefusal: LocalizedError, Equatable {
    let message: String

    var errorDescription: String? { message }
}

// A check that runs when an edit's turn comes, after every edit before it. A message from it
// refuses the edit, such as when a field on the record did not save.
struct EditCheck {
    let refusal: () -> String?
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

// Typing on screen that has not reached the queue, or that did not save: a field, a checklist,
// or a job's add line. The queue asks it to submit before any other edit, so edits save in the
// order you made them, and asks it to save everything before quitting, closing the window,
// restoring and exporting a backup.
struct TypingSource {
    // When the typing waiting to submit began, so typing submits in the order it began. Nil when
    // nothing waits to submit.
    let began: () -> EditChange?
    // Submits typing that can save, as the typing pause would.
    let submit: () -> Void
    // Submits everything it can, and tries text that did not save once more.
    let saveAll: () -> Void
    // Whether text on screen has not saved.
    let isUnsaved: () -> Bool
}

// The one queue every change to the library goes through, in the order you made the changes. It
// applies one edit at a time. Each applied edit reads the rows it changes and gives back the edit
// that undoes it, and the queue keeps that inverse under the change's number. Undo and Redo
// register on the window's undo manager with the queue as their target and the change's number
// as their value, at the moment you act, so ⌘Z always follows the order you acted in. Undo
// submits the inverse as a new edit, which the queue applies after everything before it.
@Observable
final class EditQueue {
    let coordinator: LibraryCoordinator
    // The message of the latest edit that failed in each scope, until the next edit there.
    private(set) var failures: [EditScope: String] = [:]
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
    // the text at once and saves it in order, under the way back's number. When it is gone, or
    // has nothing to put back, the stored inverse undoes the change instead.
    @ObservationIgnored private var owners: [EditChange: UndoOwner] = [:]
    // The way back of an Undo that failed, and the change that Undo was for. The change still
    // holds, so its way back does nothing and hands the inverse on to the next Undo.
    @ObservationIgnored private var retries: [EditChange: EditChange] = [:]
    // The latest Undo or Redo that failed in each scope: the change it was for and its way back.
    // Try Again there runs it once more.
    @ObservationIgnored private var failedUndos: [EditScope: FailedUndo] = [:]
    // The ways back on each undo manager's Redo list. A new action clears that list, and then
    // the queue and the owners forget what they kept for them.
    @ObservationIgnored private var redoChanges: [ObjectIdentifier: Set<EditChange>] = [:]
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

    // A change you made, other than typing, is still saving. Lists and record buttons wait.
    var isBusy: Bool { pending.contains(where: \.holdsScreen) }

    func isBusy(_ scope: EditScope) -> Bool {
        pending.contains { $0.holdsScreen && $0.scope == scope }
    }

    var isBusyWithMaterial: Bool { pending.contains { $0.holdsScreen && $0.scope.isMaterial } }

    func failure(in scope: EditScope) -> String? { failures[scope] }

    // Says why a change could not be made, where its failures show.
    func report(_ message: String, in scope: EditScope) { failures[scope] = message }

    func clearFailure(in scope: EditScope) { failures[scope] = nil }

    // Try Again for an Undo or Redo that failed in a scope runs it once more, after everything
    // submitted before. False when no Undo failed there.
    @discardableResult
    func retryUndo(in scope: EditScope) -> Bool {
        guard let failed = failedUndos.removeValue(forKey: scope) else { return false }
        retries[failed.back] = nil
        failures[scope] = nil
        flushTyping()
        enqueue(
            QueuedEdit(
                work: .reverse(failed.undone), change: failed.back, scope: scope,
                holdsScreen: failed.holdsScreen, isUndo: true, reportsFailure: true,
                requires: nil, then: nil))
        return true
    }

    // How many Undo and Redo steps the queue keeps an inverse or an owner for.
    var keptUndoCount: Int { Set(inverses.keys).union(owners.keys).count }

    // Text on screen that has not saved: typing that has not reached the queue, text the field
    // does not take yet, and text whose save failed.
    var hasUnsavedTyping: Bool { typing.values.contains { $0.isUnsaved() } }

    // Hears what the library holds after each edit. The flag says whether Undo or Redo made it.
    func listen(_ listener: @escaping (LibraryChange, Bool) -> Void) {
        listeners.append(listener)
    }

    // MARK: Submitting

    // Submits an edit you made now, after the typing on screen. With an undo manager and an
    // action name, ⌘Z undoes it, registered now. A precondition runs when the edit's turn comes;
    // a message from it refuses the edit. A failure shows in the scope unless the edit is one
    // you did not ask for, such as removing a job left blank, or its submitter shows it. An
    // edit holds the screen while it saves, unless it is as quick and local as a tick. When the
    // edit changes the screen before it saves, as a tick does, its Undo and Redo go to the owner
    // first.
    @discardableResult
    func submit(
        _ edit: LibraryEdit, in scope: EditScope, undo actionName: String? = nil,
        undoManager: UndoManager? = nil, holdsScreen: Bool = true, reportsFailure: Bool = true,
        requires: EditCheck? = nil, then: ((EditResult) -> Void)? = nil,
        owner: UndoOwner? = nil
    ) -> EditTicket {
        flushTyping()
        var change: EditChange?
        if let actionName, let undoManager {
            let step = EditUndoStep(
                change: makeChange(), actionName: actionName, scope: scope,
                holdsScreen: holdsScreen)
            register(step, on: undoManager)
            change = step.change
            owners[step.change] = owner
        }
        if reportsFailure { failures[scope] = nil }
        return enqueue(
            QueuedEdit(
                work: .edit(edit), change: change, scope: scope, holdsScreen: holdsScreen,
                isUndo: false, reportsFailure: reportsFailure, requires: requires, then: then))
    }

    // Starts a burst of typing: one Undo step, registered now, whose edit comes once the typing
    // pauses or focus leaves. Its Undo and Redo go to the owner first.
    func beginTyping(
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

    // Submits typing as the edit of its burst. Typing never holds the screen, and its failure
    // goes back to the field that submitted it.
    @discardableResult
    func submitTyping(
        _ edit: LibraryEdit, in scope: EditScope, as change: EditChange?,
        then: @escaping (EditResult) -> Void
    ) -> EditTicket {
        flushTyping()
        return enqueue(
            QueuedEdit(
                work: .edit(edit), change: change, scope: scope, holdsScreen: false,
                isUndo: false, reportsFailure: false, requires: nil, then: then))
    }

    // Stops an edit before it runs, or while it runs if it can stop, such as an import.
    func cancel(_ ticket: EditTicket) {
        if let running, running.ticket === ticket {
            running.task.cancel()
        } else if let index = pending.firstIndex(where: { $0.ticket === ticket }) {
            let item = pending.remove(at: index)
            let result = EditResult.failed(CancellationError())
            item.ticket.finish(result)
            item.then?(result)
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

    // Waits until every edit submitted so far, and every edit they led to, has run.
    func waitUntilIdle() async {
        guard !pending.isEmpty else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // The one wait before quitting, closing the window, restoring and exporting a backup. Every
    // field saves what it can, text that did not save is tried once more, and the queue runs
    // until nothing waits. True when no text on screen is left unsaved.
    func saveEverything() async -> Bool {
        repeat {
            isSubmittingTyping = true
            for source in sources() { source.saveAll() }
            isSubmittingTyping = false
            await waitUntilIdle()
        } while !pending.isEmpty
        return !hasUnsavedTyping
    }

    // MARK: Undo

    // Forgets every Undo step, such as before a restore replaces the library.
    func discardUndo() {
        for undoManager in undoManagers.allObjects {
            undoManager.removeAllActions(withTarget: self)
            for typing in localTyping.values {
                undoManager.removeAllActions(withTarget: typing)
            }
        }
        inverses = [:]
        owners = [:]
        retries = [:]
        failedUndos = [:]
        redoChanges = [:]
    }

    // A step the undo manager no longer holds needs nothing kept for it.
    private func forget(_ change: EditChange) {
        inverses[change] = nil
        retries[change] = nil
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
        failures[step.scope] = nil
        if let owner = owners[step.change],
            case .done(let canRedo) = owner.undo(step.change, back.change)
        {
            inverses[step.change] = nil
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
                holdsScreen: step.holdsScreen, isUndo: true, reportsFailure: true, requires: nil,
                then: nil))
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
        if worker == nil { worker = Task { await drain() } }
        return item.ticket
    }

    private func drain() async {
        while let item = pending.first {
            let result = await run(item)
            pending.removeFirst()
            finish(item, with: result)
        }
        worker = nil
        let waiting = idleWaiters
        idleWaiters = []
        for waiter in waiting { waiter.resume() }
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
            if let undone = retries.removeValue(forKey: change), let back = item.change {
                inverses[back] = inverses.removeValue(forKey: undone)
                failedUndos = failedUndos.filter { $0.value.back != change }
                return .saved(EditApplied())
            }
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
    // that saved uses up the inverse it applied. One that failed leaves it, so the next Undo of
    // the change can try again.
    private func finish(_ item: QueuedEdit, with result: EditResult) {
        switch result {
        case .saved(let applied):
            if case .reverse(let undone) = item.work {
                inverses[undone] = nil
                owners.removeValue(forKey: undone)?.forget(undone)
            }
            if let change = item.change, let inverse = applied.inverse {
                inverses[change] = inverse
            }
            for change in applied.changes {
                for listener in listeners { listener(change, item.isUndo) }
            }
        case .failed(let error):
            if case .reverse(let undone) = item.work, let back = item.change {
                retries[back] = undone
                failedUndos[item.scope] = FailedUndo(
                    undone: undone, back: back, holdsScreen: item.holdsScreen)
            }
            if item.reportsFailure, !(error is CancellationError) {
                failures[item.scope] = error.localizedDescription
            }
        }
        item.ticket.finish(result)
        item.then?(result)
    }
}

private nonisolated struct FailedUndo: Sendable {
    let undone: EditChange
    let back: EditChange
    let holdsScreen: Bool
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
    let reportsFailure: Bool
    let requires: EditCheck?
    let then: ((EditResult) -> Void)?
    let ticket: EditTicket

    init(
        work: Work, change: EditChange?, scope: EditScope, holdsScreen: Bool, isUndo: Bool,
        reportsFailure: Bool, requires: EditCheck?, then: ((EditResult) -> Void)?
    ) {
        self.work = work
        self.change = change
        self.scope = scope
        self.holdsScreen = holdsScreen
        self.isUndo = isUndo
        self.reportsFailure = reportsFailure
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
