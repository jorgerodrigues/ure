import Foundation
import GRDB
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

    // The page where a message about a change in this scope shows. Notes and a checklist show
    // theirs on the page of their record.
    var page: EditScope {
        switch self {
        case .notes(.watch): .watches
        case .notes(.caliber): .calibers
        case .notes(.job), .checklist: .jobs
        case .calibers, .watches, .jobs, .parts, .material: self
        }
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
// inverse as a new edit, which waits like any other. An Undo or Redo that a rule of the library
// refuses when its turn comes is skipped, with the rule's message on the record's page, because
// a change made after its step, such as Start Job, can leave it nothing it may do.
@Observable
final class EditQueue {
    let coordinator: LibraryCoordinator
    // Why the queue stopped, in one plain sentence, such as "The disk is full." Nil while edits
    // run.
    private(set) var failure: String?
    // The failed edit's error as the library gave it, for the help tag of the failure bar.
    private(set) var failureDetails: String?
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

    // The queue stopped while a change waits that the screen does not show until it saves, such
    // as a deletion or an archive. The record pages take no edits then, because an edit made on
    // them could depend on a change that is not there yet. During normal saving there is no
    // hold, because nothing can be done in the moment before the change saves, and a field that
    // has the cursor keeps it.
    var holdsRecords: Bool { failure != nil && pending.contains(where: \.holdsScreen) }

    // A record whose deletion or archive waits or runs, during normal saving too, while the queue
    // is stopped, and while Try Again runs it. An edit to the record made meanwhile would fail
    // for good after it, so the record takes no edits. Every other record does.
    func isEnding(_ record: EndedRecord) -> Bool {
        waitingEdits().contains { $0.endedRecord == record }
    }

    // A spare whose use waits or runs, so it is offered to no other line.
    func isUsingSpare(_ id: UUID) -> Bool { waitingEdits().contains { $0.usedSpare == id } }

    // The edits that wait or run. An Undo is the inverse it will apply, once its change saved.
    private func waitingEdits() -> [LibraryEdit] {
        pending.compactMap { item in
            switch item.work {
            case .edit(let edit): edit
            case .reverse(let change): inverses[change]
            }
        }
    }

    // A change you made, other than typing, is still saving. Lists and record buttons wait.
    var isBusy: Bool { pending.contains(where: \.holdsScreen) }

    func isBusy(_ scope: EditScope) -> Bool {
        pending.contains { $0.holdsScreen && $0.scope == scope }
    }

    var isBusyWithMaterial: Bool { pending.contains { $0.holdsScreen && $0.scope.isMaterial } }

    func refusal(in scope: EditScope) -> String? { refusals[scope.page] }

    // Says why a change could not be made, where the change was made.
    func report(_ message: String, in scope: EditScope) { refusals[scope.page] = message }

    func clearRefusal(in scope: EditScope) { refusals[scope.page] = nil }

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
        failureDetails = nil
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
        failureDetails = nil
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
        refusals[scope.page] = nil
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

    // One plain sentence for why an edit failed. A database error never shows its SQL: it says
    // what went wrong in words. A rule of the app already says it in words.
    nonisolated static func reason(for error: any Error) -> String {
        guard let error = error as? DatabaseError else { return error.localizedDescription }
        switch error.resultCode {
        case .SQLITE_FULL: return "The disk is full."
        case .SQLITE_BUSY, .SQLITE_LOCKED: return "The library was busy."
        default: return "The library couldn’t be written to."
        }
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

    // Undo and Redo. The way back registers now, under a new change. The rest of the typing
    // submits first. The change's owner then puts back its text at once and submits it under
    // that number, so typing that follows builds on it. Without an owner, the inverse submits,
    // and it is read once the change itself has run.
    private func reverse(_ step: EditUndoStep, undoManager: UndoManager?) {
        var wayBack = WayBack.undo
        if let undoManager, undoManager.isRedoing {
            redoChanges[ObjectIdentifier(undoManager)]?.remove(step.change)
            wayBack = .redo
        }
        let back = EditUndoStep(
            change: makeChange(), actionName: step.actionName, scope: step.scope,
            holdsScreen: step.holdsScreen)
        refusals[step.scope.page] = nil
        flushTyping()
        if let owner = owners[step.change] {
            let submitted = pending.count
            if case .done(let canRedo) = owner.undo(step.change, back.change) {
                for index in pending.indices where index >= submitted {
                    pending[index].wayBack = wayBack
                }
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
        }
        if let undoManager { register(back, on: undoManager) }
        var item = QueuedEdit(
            work: .reverse(step.change), change: back.change, scope: step.scope,
            holdsScreen: step.holdsScreen, isUndo: true, requires: nil, then: nil)
        item.wayBack = wayBack
        enqueue(item)
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
    // Try Again runs it again.
    private func drain() async {
        while failure == nil, let item = pending.first {
            let result = await run(item)
            if let error = result.error, !Self.goesOn(after: item, error) {
                failure = Self.reason(for: error)
                failureDetails = String(describing: error)
                break
            }
            pending.removeFirst()
            finish(item, with: result)
        }
        worker = nil
        resumeIdleWaiters()
    }

    // An edit that you stopped, such as an import, is not a failure. Nor is an Undo or Redo
    // that a rule refuses: it changed nothing, Try Again would get the same answer, and AppKit
    // took its step when you pressed ⌘Z, so it could not be refused then. A disk or database
    // error in an Undo still stops the queue, because Try Again can get past it.
    private static func goesOn(after item: QueuedEdit, _ error: any Error) -> Bool {
        if error is CancellationError { return true }
        return item.wayBack != nil && error is RuleError
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
    // uses up the inverse of its step, also when a rule skipped it. A skipped Undo or Redo says
    // why on the record's page.
    private func finish(_ item: QueuedEdit, with result: EditResult) {
        if case .reverse(let undone) = item.work {
            inverses[undone] = nil
            owners.removeValue(forKey: undone)?.forget(undone)
        }
        switch result {
        case .saved(let applied):
            if let change = item.change, !retired.contains(change), let inverse = applied.inverse {
                inverses[change] = inverse
            }
            for change in applied.changes {
                for listener in listeners { listener(change, item.isUndo) }
            }
        case .failed(let error):
            if let wayBack = item.wayBack, error is RuleError {
                refusals[item.scope.page] = "\(wayBack.nothingDone) \(Self.reason(for: error))"
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
    // Set for the edit of an Undo or Redo, also when the field or checklist that made the change
    // submits it.
    var wayBack: WayBack?

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

private enum WayBack {
    case undo
    case redo

    var nothingDone: String {
        switch self {
        case .undo: "Nothing was undone."
        case .redo: "Nothing was redone."
        }
    }
}

// The target of the Undo steps of one line's typing that saves nowhere. The queue keeps it, so
// the target lives as long as the library is open.
private final class LocalTyping {
    var restore: (([String]) -> [String])?
}
