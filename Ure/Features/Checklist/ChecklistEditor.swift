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
// that have not saved on top, so an Undo and a change made while it waits keep each other. A step without text stays on screen while you type in
// it and is never saved. When you leave it, it goes.
//
// The row after the last step adds a step. Typing in it makes a step there, and a new row to
// add one comes after it.
@Observable
final class ChecklistEditor {
    static let typingPause: Duration = .milliseconds(500)
    static let headingMark = "# "

    let jobID: UUID
    private(set) var steps: [ChecklistStep]
    // The steps the library holds, or will hold once this checklist's edits have run.
    private(set) var savedSteps: [ChecklistStep]
    // An edit of this checklist is still waiting in the queue.
    private(set) var isSaving = false
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
    // The step that the burst of typing going on is in. Its Undo is already registered.
    @ObservationIgnored private var typingID: UUID?
    // The Undo step that the steps on screen belong to while they have not saved.
    @ObservationIgnored private var unsavedChange: EditChange?
    // What the library holds, as far as this checklist knows.
    @ObservationIgnored private var storedSteps: [ChecklistStep]
    @ObservationIgnored private var latest: EditTicket?
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
    var hasUnsavedChanges: Bool { Self.kept(steps) != savedSteps || isSaving }
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
        saveNow()
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
        saveNow()
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
        saveNow()
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
            saveNow()
        } else {
            commit("Delete Step", undoManager: undoManager)
        }
    }

    // MARK: Saving

    // Shows the stored steps once this checklist's own changes have saved. The library's
    // reports can come from before a change, so they wait while a step has the cursor. What the
    // queue reports after an edit, Undo included, shows at once.
    func refresh(_ stored: [ChecklistStep], fromQueue: Bool = false) {
        guard !isSaving, fromQueue || editingID == nil else { return }
        show(stored)
    }

    // Submits the changed steps now. Try Again calls it too.
    func saveNow() {
        scheduledSave?.cancel()
        scheduledSave = nil
        typingID = nil
        defer { track() }
        let value = Self.kept(steps)
        let operations = ChecklistOperation.changes(from: savedSteps, to: value)
        guard !operations.isEmpty else {
            settle()
            return
        }
        let change = unsavedChange
        unsavedChange = nil
        savedSteps = value
        isSaving = true
        latest = queue.submitTyping(.checklist(jobID, operations), in: scope, as: change) {
            [weak self] result in self?.finished(value, change: change, result: result)
        }
    }

    // The stored steps with the changes made here that have not saved on top. An empty step on
    // screen stays after the step before it.
    private func show(_ stored: [ChecklistStep]) {
        let kept = Self.kept(stored)
        let local = ChecklistOperation.changes(
            from: savedSteps, to: steps.filter { !$0.isBlank })
        var shown = ChecklistOperation.applying(local, to: kept).steps
        for (index, step) in steps.enumerated() where step.isBlank {
            let ids = Set(shown.map(\.id))
            let previous = steps[..<index].last { ids.contains($0.id) }
            let place = previous.flatMap { previous in shown.firstIndex { $0.id == previous.id } }
            shown.insert(step, at: place.map { $0 + 1 } ?? 0)
        }
        steps = shown
        savedSteps = kept
        storedSteps = kept
    }

    // The steps as they are saved: those with text, without the spaces around it.
    static func kept(_ steps: [ChecklistStep]) -> [ChecklistStep] {
        steps.filter { !$0.isBlank }.map(\.saved)
    }

    // A failure of the latest save keeps its steps on screen as not saved. An older one that a
    // later save took over settles.
    private func finished(_ value: [ChecklistStep], change: EditChange?, result: EditResult) {
        if latest?.isPending != true { isSaving = false }
        switch result {
        case .saved:
            if savedSteps == value { ownError = nil }
            if !isSaving {
                for case .checklist(let job, let records) in result.changes where job == jobID {
                    show(records.map(ChecklistStep.init(record:)))
                }
            }
        case .failed(let error):
            ownError = error.localizedDescription
            if savedSteps == value {
                savedSteps = storedSteps
                if unsavedChange == nil { unsavedChange = change }
            } else if let change {
                queue.typingSettled(change)
            }
        }
        track()
    }

    private func scheduleSave() {
        scheduledSave?.cancel()
        scheduledSave = Task { [weak self, pause] in
            do { try await pause(Self.typingPause) } catch { return }
            guard !Task.isCancelled, let self else { return }
            scheduledSave = nil
            saveNow()
        }
    }

    private func settle() {
        guard let unsavedChange else { return }
        queue.typingSettled(unsavedChange)
        self.unsavedChange = nil
    }

    // MARK: Changes other than typing

    // Typing on screen, here and elsewhere, submits before a change, so the change and its
    // Undo come after it.
    private func beginChange() {
        scheduledSave?.cancel()
        scheduledSave = nil
        if typingID != nil { saveNow() }
        queue.flushTyping()
    }

    // Submits the changed steps as one change with its own Undo step, registered now. When the
    // change did not save, its Undo takes it back from the screen.
    private func commit(_ actionName: String, undoManager: UndoManager?) {
        let value = Self.kept(steps)
        let operations = ChecklistOperation.changes(from: savedSteps, to: value)
        guard !operations.isEmpty else { return }
        savedSteps = value
        isSaving = true
        latest = queue.submit(
            .checklist(jobID, operations), in: scope, undo: actionName,
            undoManager: undoManager, holdsScreen: false, reportsFailure: false,
            then: { [weak self] result in self?.finished(value, change: nil, result: result) },
            onUndo: { [weak self] _ in self?.dropUnsavedChanges() })
        track()
    }

    // MARK: Undo

    // The first change of a burst of typing in a step registers its Undo. Typing in another
    // step ends the burst before.
    private func beginTyping(_ id: UUID, undoManager: UndoManager?) {
        guard typingID != id else { return }
        if typingID != nil { saveNow() }
        typingID = id
        guard unsavedChange == nil else { return }
        unsavedChange = queue.beginTyping(
            "Typing", in: scope, undoManager: undoManager
        ) { [weak self] change in self?.undoReachedTyping(change) }
    }

    // Undo reached the typing while it was still on screen. Steps that can save submit first,
    // so the Undo that follows takes them back from the library. Steps that did not save go
    // back to the stored steps.
    private func undoReachedTyping(_ change: EditChange) {
        guard unsavedChange == change else { return }
        if typingID != nil, ownError == nil {
            saveNow()
            return
        }
        dropUnsavedChanges()
    }

    // Undo of a change that did not save takes back what did not save.
    private func dropUnsavedChanges() {
        guard ownError != nil || typingID != nil else { return }
        scheduledSave?.cancel()
        scheduledSave = nil
        typingID = nil
        if let unsavedChange { queue.typingSettled(unsavedChange) }
        unsavedChange = nil
        ownError = nil
        steps = storedSteps
        savedSteps = storedSteps
        track()
    }

    // The queue asks the checklist to submit before other edits, and before quitting.
    private func track() {
        let unsaved = Self.kept(steps) != savedSteps || typingID != nil
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
                    saveNow()
                },
                saveAll: { [weak self] in self?.saveNow() },
                isUnsaved: { [weak self] in
                    guard let self else { return false }
                    return Self.kept(steps) != savedSteps
                }))
    }
}
