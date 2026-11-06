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

// One job's checklist as you type it. The steps on screen are what you see, and the screen is
// what counts: each save sends what the screen shows that the library will not hold, as changes
// of the steps and properties that differ, on the library's queue. Typing saves half a second
// after it stops and when you leave the step, and a tick, a heading, a move or a removal saves
// at once. A save that fails leaves the screen as it is, with Try Again, and the next save sends
// it too, as the whole list did before the queue. Each burst of typing in a step and each other
// change is one Undo step, which keeps what the change did on screen. Undo puts back the steps
// as they showed before it, and Redo as they showed after it, and either then saves like any
// change. A step without text stays on screen while you type in it and is never saved. When you
// leave it, it goes.
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
    // Why the latest save failed, until the next save goes or nothing is left unsaved.
    private var ownError: String?
    // The step whose text has the cursor.
    private(set) var editingID: UUID?
    // The row after the last step that adds a step.
    private(set) var addID = UUID()
    private(set) var focusRequest: StepFocus?
    @ObservationIgnored var editingChanged: (UUID?) -> Void = { _ in }
    @ObservationIgnored private let queue: EditQueue
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    @ObservationIgnored private var scheduledSave: Task<Void, Never>?
    // The step that the burst of typing going on is in, its Undo step, and the steps as they
    // showed when the typing began.
    @ObservationIgnored private var typingID: UUID?
    @ObservationIgnored private var typingChange: EditChange?
    @ObservationIgnored private var typingBefore: [ChecklistStep] = []
    // What each of this checklist's Undo and Redo steps did on screen.
    @ObservationIgnored private var screenChanges: [EditChange: ScreenChange] = [:]
    // What the library holds, as far as this checklist knows.
    @ObservationIgnored private var storedSteps: [ChecklistStep]
    // This checklist's saves still on their way to the library, in the order they went.
    @ObservationIgnored private var inFlight: [ChecklistSubmission] = []
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
    private var hasUnsavedSteps: Bool { !unsubmitted().isEmpty }
    // A save of this checklist failed, here or in an Undo of it. Its own failure shows only while
    // the screen holds something that the library will not.
    var saveError: String? {
        if hasUnsavedSteps, let ownError { return ownError }
        return queue.failure(in: scope)
    }

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
        if typingID != nil { submitTyping() }
        editingID = id
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
        let before = beginChange()
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].text = textBeforeEditing
        commit("Typing", from: before, undoManager: undoManager)
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
        let before = beginChange()
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        let actionName = steps[index].isTicked ? "Untick Step" : "Tick Step"
        steps[index].isTicked.toggle()
        commit(actionName, from: before, undoManager: undoManager)
    }

    func toggleHeading(_ id: UUID, undoManager: UndoManager?) {
        guard canChange(id) else { return }
        let before = beginChange()
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        let actionName = steps[index].isHeading ? "Make Step" : "Make Heading"
        steps[index].isHeading.toggle()
        steps[index].isTicked = false
        commit(actionName, from: before, undoManager: undoManager)
    }

    // Moves a step one place up or down. A step you are typing in keeps the cursor.
    func move(_ id: UUID, by offset: Int, undoManager: UndoManager?) {
        guard canMove(id, by: offset) else { return }
        let before = beginChange()
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps.swapAt(index, index + offset)
        if editingID == id { focusRequest = StepFocus(id: id, cursor: .end) }
        commit("Move Step", from: before, undoManager: undoManager)
    }

    func delete(_ id: UUID, undoManager: UndoManager?) {
        guard let step = step(id) else { return }
        let before = beginChange()
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        if editingID == id, index > 0 {
            focusRequest = StepFocus(id: steps[index - 1].id, cursor: .end)
        }
        steps.remove(at: index)
        if step.isBlank {
            submitTyping()
        } else {
            commit("Delete Step", from: before, undoManager: undoManager)
        }
    }

    // MARK: Saving

    // Shows the stored steps once this checklist's own changes have saved. The library's
    // reports can come from before a change, so they wait while a step has the cursor. What the
    // queue reports after an edit, Undo included, shows at once. What the screen shows that the
    // library will not hold stays on top.
    func refresh(_ stored: [ChecklistStep], fromQueue: Bool = false) {
        guard fromQueue || (!isSaving && editingID == nil) else { return }
        let local = ChecklistOperation.changes(from: savedSteps, to: steps.filter { !$0.isBlank })
        storedSteps = Self.kept(stored)
        savedSteps = expectedSteps()
        show(ChecklistOperation.applying(local, to: savedSteps).steps)
    }

    // Try Again, and saving everything before quitting: an Undo of the checklist that failed
    // runs once more, and then the screen saves, typing included.
    func saveNow() {
        queue.retryUndo(in: scope)
        submitTyping()
    }

    // The steps as they are saved: those with text, without the spaces around it.
    static func kept(_ steps: [ChecklistStep]) -> [ChecklistStep] {
        steps.filter { !$0.isBlank }.map(\.saved)
    }

    // Ends the burst of typing, as the typing pause does, when you leave a step, and before any
    // other edit, and saves the screen.
    private func submitTyping() {
        save(as: endTyping())
        track()
    }

    // Sends what the screen shows that the library will not hold, under an Undo step's number.
    // With nothing to send, nothing is left unsaved, so an earlier failure is gone too.
    private func save(as change: EditChange?) {
        ownError = nil
        let operations = unsubmitted()
        guard !operations.isEmpty else { return }
        lastNumber += 1
        let number = lastNumber
        inFlight.append(ChecklistSubmission(number: number, operations: operations))
        isSaving = true
        savedSteps = expectedSteps()
        queue.submitTyping(.checklist(jobID, operations), in: scope, as: change) {
            [weak self] result in self?.finished(number, result: result)
        }
    }

    // What the library will hold once this checklist's changes on their way have run.
    private func expectedSteps() -> [ChecklistStep] {
        ChecklistOperation.applying(inFlight.flatMap(\.operations), to: storedSteps).steps
    }

    // What the screen shows that the library will not hold.
    private func unsubmitted() -> [ChecklistOperation] {
        ChecklistOperation.changes(from: savedSteps, to: Self.kept(steps))
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

    // A save that failed leaves the screen as it is. What it did not save stays unsaved, with
    // Try Again, and the next save sends it too.
    private func finished(_ number: Int, result: EditResult) {
        inFlight.removeAll { $0.number == number }
        isSaving = !inFlight.isEmpty
        savedSteps = expectedSteps()
        if let error = result.error {
            ownError = error.localizedDescription
        } else if !hasUnsavedSteps {
            ownError = nil
        }
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

    // MARK: Changes other than typing

    // Typing on screen, here and elsewhere, submits before a change, so the change and its
    // Undo come after it. The steps as they show then are what the change starts from.
    private func beginChange() -> [ChecklistStep] {
        if typingID != nil { submitTyping() }
        queue.flushTyping()
        return steps
    }

    // Registers the change on screen as one Undo step, now, and saves the screen.
    private func commit(
        _ actionName: String, from before: [ChecklistStep], undoManager: UndoManager?
    ) {
        let forward = ChecklistOperation.changes(from: before, to: steps)
        guard !forward.isEmpty else { return }
        let change = queue.registerStep(
            actionName, in: scope, undoManager: undoManager, owner: undoOwner)
        if let change { screenChanges[change] = ScreenChange(forward, from: before) }
        save(as: change)
        track()
    }

    // MARK: Undo

    // The first change of a burst of typing in a step registers its Undo. Typing in another
    // step ends the burst before.
    private func beginTyping(_ id: UUID, undoManager: UndoManager?) {
        guard typingID != id else { return }
        if typingID != nil { submitTyping() }
        typingID = id
        typingBefore = steps
        typingChange = queue.registerStep(
            "Typing", in: scope, undoManager: undoManager, owner: undoOwner)
    }

    // Ends the burst of typing going on. Its Undo step keeps what the typing did to its step on
    // screen, spaces and all.
    private func endTyping() -> EditChange? {
        scheduledSave?.cancel()
        scheduledSave = nil
        guard let id = typingID else { return nil }
        let change = typingChange
        typingID = nil
        typingChange = nil
        if let change {
            let forward = ChecklistOperation.changes(from: typingBefore, to: steps)
                .filter { $0.stepID == id }
            screenChanges[change] = ScreenChange(forward, from: typingBefore)
        }
        typingBefore = []
        return change
    }

    private var undoOwner: UndoOwner {
        UndoOwner(
            undo: { [weak self] undone, back in self?.undo(undone, back: back) ?? .notMine },
            forget: { [weak self] change in self?.screenChanges[change] = nil })
    }

    // Undo or Redo of one of this checklist's changes puts back the steps on screen at once, as
    // they showed before the change, step by step and property by property, also when the change
    // never saved. Then the screen saves after everything before it, under the way back's
    // number. Redo puts back what the change did.
    private func undo(_ change: EditChange, back: EditChange) -> UndoHandling {
        if typingChange == change { _ = endTyping() }
        guard let recorded = screenChanges.removeValue(forKey: change) else { return .notMine }
        steps = ChecklistOperation.applying(recorded.inverse, to: steps).steps
        screenChanges[back] = recorded.reversed
        save(as: back)
        track()
        return .done(redo: .checklist(jobID, recorded.forward))
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
                    return typingChange
                },
                submit: { [weak self] in
                    guard let self, typingID != nil else { return }
                    submitTyping()
                },
                saveAll: { [weak self] in self?.saveNow() },
                isUnsaved: { [weak self] in self?.hasUnsavedSteps ?? false }))
    }
}

// What one change did to the steps on screen, and what takes it back.
private struct ScreenChange {
    let forward: [ChecklistOperation]
    let inverse: [ChecklistOperation]

    init(_ forward: [ChecklistOperation], from before: [ChecklistStep]) {
        self.forward = forward
        inverse = ChecklistOperation.applying(forward, to: before).inverse
    }

    private init(forward: [ChecklistOperation], inverse: [ChecklistOperation]) {
        self.forward = forward
        self.inverse = inverse
    }

    // The change that Redo makes after Undo.
    var reversed: ScreenChange { ScreenChange(forward: inverse, inverse: forward) }
}

// One save of a checklist on its way to the library.
private struct ChecklistSubmission {
    let number: Int
    let operations: [ChecklistOperation]
}
