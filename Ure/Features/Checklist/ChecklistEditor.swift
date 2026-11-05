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
// on their own: a change of text half a second after typing stops and when you leave the step,
// and a tick, a heading, a move or a removal at once. Each burst of typing in a step and each
// other change is one Undo step, and Undo and Redo save again. A step without text stays on
// screen while you type in it and is never saved. When you leave it, it goes.
//
// The row after the last step adds a step. Typing in it makes a step there, and a new row to
// add one comes after it.
@Observable
final class ChecklistEditor {
    static let typingPause: Duration = .milliseconds(500)
    static let headingMark = "# "

    let jobID: UUID
    private(set) var steps: [ChecklistStep]
    private(set) var savedSteps: [ChecklistStep]
    private(set) var isSaving = false
    private(set) var saveError: String?
    // The step whose text has the cursor.
    private(set) var editingID: UUID?
    // The row after the last step that adds a step.
    private(set) var addID = UUID()
    private(set) var focusRequest: StepFocus?
    @ObservationIgnored var editingChanged: (UUID?) -> Void = { _ in }
    @ObservationIgnored private let save: ([ChecklistStep]) async throws -> Void
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    @ObservationIgnored private var scheduledSave: Task<Void, Never>?
    @ObservationIgnored private var runningSave: Task<Bool, Never>?
    // The step that the burst of typing going on is in. Its Undo is already registered.
    @ObservationIgnored private var typingID: UUID?
    @ObservationIgnored private var textBeforeEditing: String?
    @ObservationIgnored private weak var undoManager: UndoManager?

    init(
        jobID: UUID, steps: [ChecklistStep],
        save: @escaping ([ChecklistStep]) async throws -> Void,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.jobID = jobID
        self.steps = steps
        savedSteps = Self.kept(steps)
        self.save = save
        self.pause = pause
    }

    var progress: ChecklistProgress { ChecklistProgress(steps) }
    var hasUnsavedChanges: Bool { Self.kept(steps) != savedSteps || isSaving }

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
        typingID = nil
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
            guard let index = steps.firstIndex(where: { $0.id == id }), steps[index].text != text
            else { return }
            beginTyping(id, undoManager: undoManager)
            steps[index].text = text
        }
        if let index = steps.firstIndex(where: { $0.id == id }), !steps[index].isHeading,
            steps[index].text.hasPrefix(Self.headingMark)
        {
            steps[index].isHeading = true
            steps[index].isTicked = false
            steps[index].text.removeFirst(Self.headingMark.count)
        }
        scheduleSave()
    }

    // Esc puts back the step's text as it was when the cursor came into it.
    func revert(_ id: UUID, undoManager: UndoManager?) {
        guard let textBeforeEditing, let index = steps.firstIndex(where: { $0.id == id }),
            steps[index].text != textBeforeEditing
        else { return }
        typingID = nil
        register(actionName: "Typing", undoManager: undoManager)
        steps[index].text = textBeforeEditing
        saveNow()
    }

    // MARK: Keys

    // Return starts the next step, after this one. After the last step, the row that adds a
    // step takes the cursor. False when the step has no text, so Return moves on instead.
    @discardableResult
    func startNextStep(after id: UUID) -> Bool {
        guard let index = steps.firstIndex(where: { $0.id == id }), !steps[index].isBlank else {
            return false
        }
        typingID = nil
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
        typingID = nil
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
        guard canTick(id), let index = steps.firstIndex(where: { $0.id == id }) else { return }
        typingID = nil
        register(
            actionName: steps[index].isTicked ? "Untick Step" : "Tick Step",
            undoManager: undoManager)
        steps[index].isTicked.toggle()
        saveNow()
    }

    func toggleHeading(_ id: UUID, undoManager: UndoManager?) {
        guard canChange(id), let index = steps.firstIndex(where: { $0.id == id }) else { return }
        typingID = nil
        register(
            actionName: steps[index].isHeading ? "Make Step" : "Make Heading",
            undoManager: undoManager)
        steps[index].isHeading.toggle()
        steps[index].isTicked = false
        saveNow()
    }

    // Moves a step one place up or down. A step you are typing in keeps the cursor.
    func move(_ id: UUID, by offset: Int, undoManager: UndoManager?) {
        guard canMove(id, by: offset), let index = steps.firstIndex(where: { $0.id == id })
        else { return }
        typingID = nil
        register(actionName: "Move Step", undoManager: undoManager)
        steps.swapAt(index, index + offset)
        if editingID == id { focusRequest = StepFocus(id: id, cursor: .end) }
        saveNow()
    }

    func delete(_ id: UUID, undoManager: UndoManager?) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        typingID = nil
        if !steps[index].isBlank { register(actionName: "Delete Step", undoManager: undoManager) }
        if editingID == id, index > 0 {
            focusRequest = StepFocus(id: steps[index - 1].id, cursor: .end)
        }
        steps.remove(at: index)
        saveNow()
    }

    // MARK: Saving

    // Adopts the stored steps when nothing typed here is waiting to save.
    func refresh(_ stored: [ChecklistStep]) {
        guard editingID == nil, !hasUnsavedChanges, saveError == nil else { return }
        steps = stored
        savedSteps = Self.kept(stored)
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
            let value = Self.kept(steps)
            guard value != savedSteps else {
                saveError = nil
                return true
            }
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

    // The steps as they are saved: those with text, without the spaces around it.
    static func kept(_ steps: [ChecklistStep]) -> [ChecklistStep] {
        steps.filter { !$0.isBlank }.map(\.saved)
    }

    private func write(_ value: [ChecklistStep]) async -> Bool {
        isSaving = true
        defer { isSaving = false }
        do {
            try await save(value)
            savedSteps = value
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
            typingID = nil
            await flush()
        }
    }

    // MARK: Undo

    // The first change of a burst of typing in a step registers its Undo.
    private func beginTyping(_ id: UUID, undoManager: UndoManager?) {
        guard typingID != id else { return }
        typingID = id
        register(actionName: "Typing", undoManager: undoManager)
    }

    // Registers an Undo that puts back the steps as they are now.
    private func register(actionName: String, undoManager: UndoManager?) {
        guard let undoManager else { return }
        self.undoManager = undoManager
        let before = steps
        undoManager.registerUndo(withTarget: self) { [weak undoManager] editor in
            MainActor.assumeIsolated {
                editor.restore(before, actionName: actionName, undoManager: undoManager)
            }
        }
        undoManager.setActionName(actionName)
    }

    // Undo and Redo put back a list of steps and register the way back. A step without text
    // stays only while you type in it.
    private func restore(
        _ value: [ChecklistStep], actionName: String, undoManager: UndoManager?
    ) {
        typingID = nil
        register(actionName: actionName, undoManager: undoManager)
        steps = value.filter { !$0.isBlank || $0.id == editingID }
        saveNow()
    }
}
