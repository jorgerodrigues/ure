import Foundation
import Observation

// Where the cursor goes when a step takes it: at the start or the end of its text.
enum StepCursor: Equatable {
    case start
    case end
}

// A step that is to take the cursor, such as the next step after Return.
struct StepFocus: Equatable {
    let id: UUID
    let cursor: StepCursor
}

// One job's checklist as you type it. The steps on screen are the ones you see, and they save
// on their own, as changes of the steps that changed, on the library's queue: a change of text
// half a second after typing stops and when you leave the step, and a tick, a heading, a move
// or a removal at once. Each burst of typing in a step and each other change is one Undo step,
// which the queue undoes from the stored steps. The stored steps show with the changes made here
// that have not saved on top, so an Undo and a change made while it waits keep each other. A
// change that did not save stays on screen until Try Again saves it, under its own Undo step, or
// Undo takes back just that change. A step without text stays on screen while you type in it and
// is never saved. When you leave it, it goes.
//
// The row after the last step adds a step. Typing in it makes a step there, and a new row to
// add one comes after it.
@Observable
final class ChecklistEditor {
    static let typingPause: Duration = .milliseconds(500)
    static let headingMark = "# "

    let jobID: UUID
    private(set) var steps: [ChecklistStep]
    // The steps the library holds, or will hold once this checklist's changes on their way have
    // run.
    private(set) var savedSteps: [ChecklistStep]
    // An edit of this checklist is still waiting in the queue.
    private(set) var isSaving = false
    private var ownError: String?
    // Changes that did not save, in the order they were made.
    private var failed: [ChecklistSubmission] = []
    // The step whose text has the cursor.
    private(set) var editingID: UUID?
    // The row after the last step that adds a step.
    private(set) var addID = UUID()
    private(set) var focusRequest: StepFocus?
    @ObservationIgnored var editingChanged: (UUID?) -> Void = { _ in }
    @ObservationIgnored private let queue: EditQueue
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    @ObservationIgnored private var scheduledSave: Task<Void, Never>?
    // The step that the burst of typing going on is in. Its Undo is already registered.
    @ObservationIgnored private var typingID: UUID?
    // The Undo step that the steps on screen belong to while they have not saved.
    @ObservationIgnored private var unsavedChange: EditChange?
    // What the library holds, as far as this checklist knows.
    @ObservationIgnored private var storedSteps: [ChecklistStep]
    // This checklist's changes still on their way to the library, in the order they went.
    @ObservationIgnored private var inFlight: [ChecklistSubmission] = []
    // What each of this checklist's Undo and Redo steps does to the steps.
    @ObservationIgnored private var undoOperations: [EditChange: [ChecklistOperation]] = [:]
    // Changes taken back by Undo while they were still on their way. If one then fails, it is
    // gone already.
    @ObservationIgnored private var undoneChanges: Set<EditChange> = []
    @ObservationIgnored private var lastNumber = 0
    @ObservationIgnored private var textBeforeEditing: String?
    @ObservationIgnored private var isTracked = false

    init(
        jobID: UUID, steps: [ChecklistStep], queue: EditQueue,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.jobID = jobID
        self.steps = steps
        savedSteps = Self.kept(steps)
        storedSteps = Self.kept(steps)
        self.queue = queue
        self.pause = pause
    }

    var progress: ChecklistProgress { ChecklistProgress(steps) }
    var hasUnsavedChanges: Bool { hasUnsavedSteps || isSaving }

    // Steps on screen that the library does not hold and no edit on its way will give it.
    private var hasUnsavedSteps: Bool { !failed.isEmpty || !unsubmitted().isEmpty }
    // A save of this checklist failed, here or in an Undo of it.
    var saveError: String? { ownError ?? queue.failure(in: .checklist(jobID)) }

    private var scope: EditScope { .checklist(jobID) }

    func step(_ id: UUID) -> ChecklistStep? { steps.first { $0.id == id } }

    // Whether a step can be ticked, made a heading or moved. A step needs text for that.
    func canChange(_ id: UUID) -> Bool { step(id).map { !$0.isBlank } ?? false }
    func canTick(_ id: UUID) -> Bool { step(id).map { !$0.isBlank && !$0.isHeading } ?? false }

    func canMove(_ id: UUID, by offset: Int) -> Bool {
        guard canChange(id), let index = steps.firstIndex(where: { $0.id == id }) else {
            return false
        }
        return steps.indices.contains(index + offset)
    }

    // MARK: Typing

    func beginEditing(_ id: UUID) {
        editingID = id
        typingID = nil
        textBeforeEditing = step(id)?.text ?? ""
        editingChanged(id)
    }

    // Leaving a step saves it at once. A step without text goes.
    func endEditing(_ id: UUID) {
        guard editingID == id else { return }
        editingID = nil
        textBeforeEditing = nil
        editingChanged(nil)
        steps.removeAll { $0.id == id && $0.isBlank }
        submitTyping()
    }

    // A change of a step's text. Typing in the row that adds a step makes a step there. A step
    // that starts with "# " becomes a heading.
    func change(_ id: UUID, to text: String, undoManager: UndoManager?) {
        if id == addID {
            guard !text.isEmpty else { return }
            beginTyping(id, undoManager: undoManager)
            steps.append(ChecklistStep(id: id, text: text))
            addID = UUID()
        } else {
            guard steps.contains(where: { $0.id == id && $0.text != text }) else { return }
            beginTyping(id, undoManager: undoManager)
            guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
            steps[index].text = text
        }
        if let index = steps.firstIndex(where: { $0.id == id }), !steps[index].isHeading,
            steps[index].text.hasPrefix(Self.headingMark)
        {
            steps[index].isHeading = true
            steps[index].isTicked = false
            steps[index].text.removeFirst(Self.headingMark.count)
        }
        track()
        scheduleSave()
    }

    // Esc puts back the step's text as it was when the cursor came into it, as its own Undo
    // step after the typing.
    func revert(_ id: UUID, undoManager: UndoManager?) {
        guard let textBeforeEditing,
            steps.contains(where: { $0.id == id && $0.text != textBeforeEditing })
        else { return }
        beginChange()
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].text = textBeforeEditing
        commit("Typing", undoManager: undoManager)
    }

    // MARK: Keys

    // Return starts the next step, after this one. After the last step, the row that adds a
    // step takes the cursor. False when the step has no text, so Return moves on instead.
    @discardableResult
    func startNextStep(after id: UUID) -> Bool {
        guard let index = steps.firstIndex(where: { $0.id == id }), !steps[index].isBlank else {
            return false
        }
        submitTyping()
        if index == steps.count - 1 {
            focusRequest = StepFocus(id: addID, cursor: .start)
        } else {
            let next = ChecklistStep(id: UUID())
            steps.insert(next, at: index + 1)
            focusRequest = StepFocus(id: next.id, cursor: .start)
        }
        return true
    }

    // Backspace on a step without text removes it, and the cursor goes to the end of the step
    // before. In the row that adds a step it goes to the last step. False when there is text to
    // delete or nowhere to go.
    @discardableResult
    func removeEmptyStep(_ id: UUID) -> Bool {
        if id == addID {
            guard let last = steps.last else { return false }
            focusRequest = StepFocus(id: last.id, cursor: .end)
            return true
        }
        guard let index = steps.firstIndex(where: { $0.id == id }), steps[index].text.isEmpty
        else { return false }
        if steps[index].isHeading {
            // An empty heading becomes a step first, as Backspace removes the "#" you typed.
            steps[index].isHeading = false
            return true
        }
        if index > 0 {
            focusRequest = StepFocus(id: steps[index - 1].id, cursor: .end)
        } else if steps.count > 1 {
            focusRequest = StepFocus(id: steps[index + 1].id, cursor: .start)
        } else {
            focusRequest = StepFocus(id: addID, cursor: .start)
        }
        steps.remove(at: index)
        submitTyping()
        return true
    }

    // The Up and Down arrows move the cursor to the line before or after, including the row
    // that adds a step. False at the first and the last line.
    @discardableResult
    func focusLine(nextTo id: UUID, by offset: Int) -> Bool {
        let lines = steps.map(\.id) + [addID]
        guard let index = lines.firstIndex(of: id), lines.indices.contains(index + offset) else {
            return false
        }
        focusRequest = StepFocus(id: lines[index + offset], cursor: offset < 0 ? .end : .start)
        return true
    }

    // The step's view took the cursor it asked for.
    func focusTaken(_ id: UUID) {
        if focusRequest?.id == id { focusRequest = nil }
    }

    // MARK: Changes

    func toggleTick(_ id: UUID, undoManager: UndoManager?) {
        guard canTick(id) else { return }
        beginChange()
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        let actionName = steps[index].isTicked ? "Untick Step" : "Tick Step"
        steps[index].isTicked.toggle()
        commit(actionName, undoManager: undoManager)
    }

    func toggleHeading(_ id: UUID, undoManager: UndoManager?) {
        guard canChange(id) else { return }
        beginChange()
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        let actionName = steps[index].isHeading ? "Make Step" : "Make Heading"
        steps[index].isHeading.toggle()
        steps[index].isTicked = false
        commit(actionName, undoManager: undoManager)
    }

    // Moves a step one place up or down. A step you are typing in keeps the cursor.
    func move(_ id: UUID, by offset: Int, undoManager: UndoManager?) {
        guard canMove(id, by: offset) else { return }
        beginChange()
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps.swapAt(index, index + offset)
        if editingID == id { focusRequest = StepFocus(id: id, cursor: .end) }
        commit("Move Step", undoManager: undoManager)
    }

    func delete(_ id: UUID, undoManager: UndoManager?) {
        guard let step = step(id) else { return }
        beginChange()
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        if editingID == id, index > 0 {
            focusRequest = StepFocus(id: steps[index - 1].id, cursor: .end)
        }
        steps.remove(at: index)
        if step.isBlank {
            submitTyping()
        } else {
            commit("Delete Step", undoManager: undoManager)
        }
    }

    // MARK: Saving

    // Shows the stored steps once this checklist's own changes have saved. The library's
    // reports can come from before a change, so they wait while a step has the cursor. What the
    // queue reports after an edit, Undo included, shows at once.
    func refresh(_ stored: [ChecklistStep], fromQueue: Bool = false) {
        guard fromQueue || (!isSaving && editingID == nil) else { return }
        let local = ChecklistOperation.changes(from: base(), to: steps.filter { !$0.isBlank })
        storedSteps = Self.kept(stored)
        savedSteps = expectedSteps()
        show(ChecklistOperation.applying(local, to: base()).steps)
    }

    // Try Again: an Undo of the checklist that failed runs once more, the changes that did not
    // save go again, each under its own Undo step, and then the typing on screen.
    func saveNow() {
        queue.retryUndo(in: scope)
        let retrying = failed
        failed = []
        for entry in retrying {
            inFlight.append(entry)
            queue.submitTyping(.checklist(jobID, entry.operations), in: scope, as: entry.change) {
                [weak self] result in self?.finished(entry.number, result: result)
            }
        }
        isSaving = !inFlight.isEmpty
        savedSteps = expectedSteps()
        submitTyping()
    }

    // The steps as they are saved: those with text, without the spaces around it.
    static func kept(_ steps: [ChecklistStep]) -> [ChecklistStep] {
        steps.filter { !$0.isBlank }.map(\.saved)
    }

    // Submits the typing on screen, as the typing pause does, when you leave a step, and before
    // any other edit.
    private func submitTyping() {
        scheduledSave?.cancel()
        scheduledSave = nil
        typingID = nil
        defer { track() }
        let base = base()
        let operations = ChecklistOperation.changes(from: base, to: Self.kept(steps))
        guard !operations.isEmpty else {
            settle()
            return
        }
        let change = unsavedChange
        unsavedChange = nil
        let number = send(operations, from: base, as: change)
        queue.submitTyping(.checklist(jobID, operations), in: scope, as: change) {
            [weak self] result in self?.finished(number, result: result)
        }
    }

    // What the library will hold once this checklist's changes on their way have run.
    private func expectedSteps() -> [ChecklistStep] {
        ChecklistOperation.applying(inFlight.flatMap(\.operations), to: storedSteps).steps
    }

    // The steps on screen without the typing that has not gone yet: what the library will hold,
    // with the changes that did not save on top.
    private func base() -> [ChecklistStep] {
        ChecklistOperation.applying(failed.flatMap(\.operations), to: savedSteps).steps
    }

    private func unsubmitted() -> [ChecklistOperation] {
        ChecklistOperation.changes(from: base(), to: Self.kept(steps))
    }

    // Shows steps with text, and keeps each empty step on screen after the step before it.
    private func show(_ kept: [ChecklistStep]) {
        var shown = kept
        for (index, step) in steps.enumerated() where step.isBlank {
            let ids = Set(shown.map(\.id))
            guard !ids.contains(step.id) else { continue }
            let previous = steps[..<index].last { ids.contains($0.id) }
            let place = previous.flatMap { previous in shown.firstIndex { $0.id == previous.id } }
            shown.insert(step, at: place.map { $0 + 1 } ?? 0)
        }
        steps = shown
    }

    // Records a change on its way. What takes it back comes from the steps it changes, or is
    // given, as for an Undo.
    private func send(
        _ operations: [ChecklistOperation], from base: [ChecklistStep], as change: EditChange?,
        undo given: [ChecklistOperation]? = nil
    ) -> Int {
        lastNumber += 1
        let undo = given ?? ChecklistOperation.applying(operations, to: base).inverse
        inFlight.append(
            ChecklistSubmission(
                number: lastNumber, change: change, operations: operations, undo: undo))
        if let change { undoOperations[change] = undo }
        isSaving = true
        savedSteps = expectedSteps()
        return lastNumber
    }

    // A change that did not save stays on screen as not saved, also when a later change saved.
    private func finished(_ number: Int, result: EditResult) {
        guard let index = inFlight.firstIndex(where: { $0.number == number }) else { return }
        let entry = inFlight.remove(at: index)
        isSaving = !inFlight.isEmpty
        if case .failed(let error) = result {
            if let change = entry.change, undoneChanges.remove(change) != nil {
                // Undo took it back already.
            } else {
                ownError = error.localizedDescription
                failed.append(entry)
                failed.sort { $0.number < $1.number }
            }
        } else if let change = entry.change {
            undoneChanges.remove(change)
        }
        savedSteps = expectedSteps()
        if failed.isEmpty { ownError = nil }
        track()
    }

    private func scheduleSave() {
        scheduledSave?.cancel()
        scheduledSave = Task { [weak self, pause] in
            do { try await pause(Self.typingPause) } catch { return }
            guard !Task.isCancelled, let self else { return }
            scheduledSave = nil
            submitTyping()
        }
    }

    private func settle() { unsavedChange = nil }

    // MARK: Changes other than typing

    // Typing on screen, here and elsewhere, submits before a change, so the change and its
    // Undo come after it.
    private func beginChange() {
        scheduledSave?.cancel()
        scheduledSave = nil
        if typingID != nil { submitTyping() }
        queue.flushTyping()
    }

    // Submits the changed steps as one change with its own Undo step, registered now.
    private func commit(_ actionName: String, undoManager: UndoManager?) {
        let base = base()
        let operations = ChecklistOperation.changes(from: base, to: Self.kept(steps))
        guard !operations.isEmpty else { return }
        let number = send(operations, from: base, as: nil)
        let ticket = queue.submit(
            .checklist(jobID, operations), in: scope, undo: actionName,
            undoManager: undoManager, holdsScreen: false, reportsFailure: false,
            then: { [weak self] result in self?.finished(number, result: result) },
            owner: undoOwner)
        if let index = inFlight.firstIndex(where: { $0.number == number }),
            let change = ticket.change
        {
            inFlight[index].change = change
            undoOperations[change] = inFlight[index].undo
        }
        track()
    }

    // MARK: Undo

    // The first change of a burst of typing in a step registers its Undo. Typing in another
    // step ends the burst before.
    private func beginTyping(_ id: UUID, undoManager: UndoManager?) {
        guard typingID != id else { return }
        if typingID != nil { submitTyping() }
        typingID = id
        guard unsavedChange == nil else { return }
        unsavedChange = queue.beginTyping(
            "Typing", in: scope, undoManager: undoManager, owner: undoOwner)
    }

    private var undoOwner: UndoOwner {
        UndoOwner(
            undo: { [weak self] undone, back in self?.undo(undone, back: back) ?? .notMine },
            forget: { [weak self] change in self?.undoOperations[change] = nil })
    }

    // Undo or Redo of one of this checklist's changes takes it back on screen at once, step by
    // step and property by property, and saves that after everything before it, under the way
    // back's number. A change that never saved, such as typing still going on or a tick that
    // failed, goes from the screen and saves only what the library then needs, such as when a
    // later Undo saved the failed tick after all. Redo puts the change back and saves it then.
    private func undo(_ change: EditChange, back: EditChange) -> UndoHandling {
        let operations: [ChecklistOperation]
        var saves = true
        if unsavedChange == change, typingID != nil {
            let base = base()
            operations =
                ChecklistOperation.applying(
                    ChecklistOperation.changes(from: base, to: Self.kept(steps)), to: base
                ).inverse
            scheduledSave?.cancel()
            scheduledSave = nil
            typingID = nil
            unsavedChange = nil
            saves = false
        } else if let index = failed.firstIndex(where: { $0.change == change }) {
            operations = failed.remove(at: index).undo
            undoOperations[change] = nil
            saves = false
        } else if let stored = undoOperations.removeValue(forKey: change) {
            operations = stored
            if inFlight.contains(where: { $0.change == change }) { undoneChanges.insert(change) }
        } else {
            return .notMine
        }
        let base = base()
        let undone = ChecklistOperation.applying(operations, to: steps.filter { !$0.isBlank })
        show(undone.steps)
        var saved = operations
        if !saves {
            let ids = Set(operations.map(\.stepID))
            saved = unsubmitted().filter { ids.contains($0.stepID) }
        }
        if saved.isEmpty {
            undoOperations[back] = undone.inverse
        } else {
            let number = send(saved, from: base, as: back, undo: undone.inverse)
            queue.submitTyping(.checklist(jobID, saved), in: scope, as: back) {
                [weak self] result in self?.finished(number, result: result)
            }
        }
        if failed.isEmpty { ownError = nil }
        track()
        return .done(canRedo: true)
    }

    // The queue asks the checklist to submit before other edits, and before quitting.
    private func track() {
        let unsaved = hasUnsavedSteps || typingID != nil
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
                    guard let self, typingID != nil else { return nil }
                    return unsavedChange
                },
                submit: { [weak self] in
                    guard let self, typingID != nil else { return }
                    submitTyping()
                },
                saveAll: { [weak self] in self?.saveNow() },
                isUnsaved: { [weak self] in self?.hasUnsavedSteps ?? false }))
    }
}

// One change of a checklist on its way to the library: its Undo step, its operations, and the
// operations that take it back from the screen if it does not save.
private struct ChecklistSubmission {
    let number: Int
    var change: EditChange?
    let operations: [ChecklistOperation]
    let undo: [ChecklistOperation]
}
