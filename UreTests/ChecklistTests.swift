import AppKit
import Foundation
import GRDB
import Synchronization
import Testing

@testable import Ure

struct ChecklistEditorTests {
    @Test(.timeLimit(.minutes(1)))
    func aWholeChecklistIsTypedWithTheKeyboardAlone() async throws {
        let saves = SavedChecklists()
        let editor = ChecklistEditor(jobID: UUID(), steps: [], save: saves.save)
        let undo = Self.undoManager()
        // The row that adds a step takes the cursor, and typing in it makes a step there.
        let clean = editor.addID
        editor.beginEditing(clean)
        type("Clean all parts", in: clean, editor, undo)
        #expect(editor.steps.map(\.text) == ["Clean all parts"] && editor.addID != clean)
        // Return after the last step moves the cursor to the row that adds a step.
        #expect(editor.startNextStep(after: clean))
        let heading = try #require(take(editor.focusRequest, in: editor, leaving: clean))
        #expect(heading == editor.addID)
        // A line that starts with "#" and a space becomes a heading.
        type("# Assembly", in: heading, editor, undo)
        #expect(
            editor.step(heading) == ChecklistStep(id: heading, text: "Assembly", isHeading: true))
        #expect(editor.startNextStep(after: heading))
        let fit = try #require(take(editor.focusRequest, in: editor, leaving: heading))
        type("Fit the new mainspring", in: fit, editor, undo)
        #expect(editor.startNextStep(after: fit))
        let oil = try #require(take(editor.focusRequest, in: editor, leaving: fit))
        type("Oil the escapement", in: oil, editor, undo)
        // ⇧⌘U ticks the step, and ⌃⌘↑ moves it above the one before.
        act(undo) { editor.perform(.tick, for: oil, undoManager: undo) }
        act(undo) { editor.perform(.moveUp, for: oil, undoManager: undo) }
        #expect(editor.steps.map(\.id) == [clean, heading, oil, fit])
        #expect(editor.focusRequest == StepFocus(id: oil, cursor: .end))
        editor.focusTaken(oil)
        // Return in the middle starts an empty step after this one. Return on it moves on, and
        // Backspace removes it and puts the cursor at the end of the step before.
        #expect(editor.startNextStep(after: oil))
        let empty = try #require(take(editor.focusRequest, in: editor, leaving: oil))
        #expect(editor.steps.map(\.id) == [clean, heading, oil, empty, fit])
        #expect(!editor.startNextStep(after: empty))
        #expect(editor.removeEmptyStep(empty))
        #expect(editor.focusRequest == StepFocus(id: oil, cursor: .end))
        #expect(editor.steps.map(\.id) == [clean, heading, oil, fit])
        editor.endEditing(empty)
        #expect(await editor.flush())
        #expect(
            saves.last == [
                ChecklistStep(id: clean, text: "Clean all parts"),
                ChecklistStep(id: heading, text: "Assembly", isHeading: true),
                ChecklistStep(id: oil, text: "Oil the escapement", isTicked: true),
                ChecklistStep(id: fit, text: "Fit the new mainspring"),
            ])
        // Progress counts ticked steps and ignores headings.
        #expect(editor.progress == ChecklistProgress(saves.last ?? []))
        #expect(editor.progress.summary == "1 of 3 done" && editor.progress.fraction == 1.0 / 3)
        #expect(!editor.hasUnsavedChanges)
    }

    @Test(.timeLimit(.minutes(1)))
    func undoPutsBackEachChangeInTurnAndRedoMakesItAgain() async throws {
        let saves = SavedChecklists()
        let steps = ["Clean all parts", "Fit the new mainspring", "Regulate"].map {
            ChecklistStep(id: UUID(), text: $0)
        }
        let editor = ChecklistEditor(jobID: UUID(), steps: steps, save: saves.save)
        let undo = Self.undoManager()
        let ids = steps.map(\.id)
        editor.beginEditing(ids[1])
        type(" and set it", in: ids[1], editor, undo)
        act(undo) { editor.perform(.tick, for: ids[0], undoManager: undo) }
        act(undo) { editor.perform(.moveDown, for: ids[0], undoManager: undo) }
        act(undo) { editor.perform(.heading, for: ids[2], undoManager: undo) }
        act(undo) { editor.perform(.delete, for: ids[1], undoManager: undo) }
        #expect(editor.steps.map(\.id) == [ids[0], ids[2]])
        #expect(undo.undoActionName == "Delete Step")
        let names = ["Delete Step", "Make Heading", "Move Step", "Tick Step", "Typing"]
        for name in names {
            #expect(undo.undoActionName == name)
            undo.undo()
        }
        #expect(editor.steps == steps)
        #expect(!undo.canUndo)
        for name in names.reversed() {
            #expect(undo.redoActionName == name)
            undo.redo()
        }
        #expect(editor.steps.map(\.id) == [ids[0], ids[2]])
        #expect(editor.step(ids[0])?.isTicked == true && editor.step(ids[2])?.isHeading == true)
        // Each Undo and Redo saves again, so the library ends where the page is.
        #expect(await editor.flush())
        #expect(saves.last == ChecklistEditor.kept(editor.steps))
        undo.undo()
        #expect(await editor.flush())
        #expect(saves.last?.map(\.id) == [ids[1], ids[0], ids[2]])
    }

    @Test(.timeLimit(.minutes(1)))
    func typingSavesAfterAPauseAndEachBurstIsOneUndo() async throws {
        let saves = SavedChecklists()
        let gate = PauseGate()
        let step = ChecklistStep(id: UUID(), text: "Clean")
        let editor = ChecklistEditor(
            jobID: UUID(), steps: [step], save: saves.save, pause: gate.pause)
        let undo = Self.undoManager()
        editor.beginEditing(step.id)
        type(" all parts", in: step.id, editor, undo)
        #expect(saves.lists.isEmpty && editor.hasUnsavedChanges)
        try await gate.elapse()
        try await waitUntil { !editor.hasUnsavedChanges }
        #expect(saves.last == [ChecklistStep(id: step.id, text: "Clean all parts")])
        // Typing after the pause is a burst of its own.
        type(" twice", in: step.id, editor, undo)
        try await gate.elapse()
        try await waitUntil { !editor.hasUnsavedChanges }
        undo.undo()
        #expect(editor.step(step.id)?.text == "Clean all parts")
        undo.undo()
        #expect(editor.step(step.id)?.text == "Clean")
        // Esc puts back the text from when the cursor came in, as a change you can undo.
        type(" nothing", in: step.id, editor, undo)
        act(undo) { editor.revert(step.id, undoManager: undo) }
        #expect(editor.step(step.id)?.text == "Clean")
        // Leaving saves at once, and the saved text has no spaces around it.
        act(undo) { editor.change(step.id, to: "  Clean the case  ", undoManager: undo) }
        editor.endEditing(step.id)
        try await waitUntil { !editor.hasUnsavedChanges }
        #expect(saves.last == [ChecklistStep(id: step.id, text: "Clean the case")])
    }

    @Test
    func stepsWithoutTextStayOnlyWhileYouTypeInThem() async throws {
        let saves = SavedChecklists()
        let step = ChecklistStep(id: UUID(), text: "Clean")
        let editor = ChecklistEditor(jobID: UUID(), steps: [step], save: saves.save)
        let undo = Self.undoManager()
        // Clearing a saved step's text saves the checklist without it. Leaving it removes it.
        editor.beginEditing(step.id)
        act(undo) { editor.change(step.id, to: "", undoManager: undo) }
        #expect(editor.steps.count == 1 && editor.progress.stepCount == 0)
        #expect(!editor.canTick(step.id) && !editor.canMove(step.id, by: 1))
        editor.endEditing(step.id)
        #expect(editor.steps.isEmpty)
        #expect(await editor.flush())
        #expect(saves.last == [])
        // Undo brings back the text it had.
        undo.undo()
        #expect(editor.steps == [step])
        // Backspace in the empty row that adds a step goes to the end of the last step.
        #expect(editor.removeEmptyStep(editor.addID))
        #expect(editor.focusRequest == StepFocus(id: step.id, cursor: .end))
        // An empty heading becomes a step again on Backspace, as the "# " goes.
        let next = editor.addID
        editor.beginEditing(next)
        act(undo) { editor.change(next, to: "#", undoManager: undo) }
        act(undo) { editor.change(next, to: "# ", undoManager: undo) }
        #expect(editor.step(next) == ChecklistStep(id: next, text: "", isHeading: true))
        #expect(editor.removeEmptyStep(next))
        #expect(editor.step(next) == ChecklistStep(id: next, text: ""))
        // The arrows move between the lines, and stop at the first and the last.
        #expect(editor.focusLine(nextTo: next, by: -1))
        #expect(editor.focusRequest == StepFocus(id: step.id, cursor: .end))
        #expect(!editor.focusLine(nextTo: step.id, by: -1))
        #expect(editor.focusLine(nextTo: next, by: 1))
        #expect(editor.focusRequest == StepFocus(id: editor.addID, cursor: .start))
        #expect(!editor.focusLine(nextTo: editor.addID, by: 1))
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailedSaveKeepsTheStepsAndTryAgainSavesThem() async throws {
        let saves = SavedChecklists()
        saves.failure = SavedChecklists.Failure()
        let editor = ChecklistEditor(jobID: UUID(), steps: [], save: saves.save)
        let undo = Self.undoManager()
        let id = editor.addID
        editor.beginEditing(id)
        type("Clean all parts", in: id, editor, undo)
        editor.endEditing(id)
        try await waitUntil { editor.saveError != nil }
        #expect(editor.steps.map(\.text) == ["Clean all parts"] && editor.hasUnsavedChanges)
        // Stored steps never replace what did not save.
        editor.refresh([])
        #expect(editor.steps.map(\.text) == ["Clean all parts"])
        saves.failure = nil
        editor.saveNow()
        try await waitUntil { !editor.hasUnsavedChanges }
        #expect(editor.saveError == nil && saves.last?.map(\.text) == ["Clean all parts"])
        editor.refresh([ChecklistStep(id: id, text: "Clean all parts", isTicked: true)])
        #expect(editor.step(id)?.isTicked == true)
    }

    @Test
    func menuCommandsAreNamedForTheStepAndOfferedOnlyWhenTheyApply() {
        let steps = [
            ChecklistStep(id: UUID(), text: "Cleaning", isHeading: true),
            ChecklistStep(id: UUID(), text: "Clean all parts", isTicked: true),
        ]
        let editor = ChecklistEditor(jobID: UUID(), steps: steps, save: { _ in })
        let heading = steps[0].id
        let step = steps[1].id
        #expect(editor.title(of: .tick, for: step) == "Untick Step")
        #expect(editor.title(of: .heading, for: heading) == "Make Step")
        #expect(editor.title(of: .delete, for: heading) == "Delete Heading")
        #expect(StepCommand.tick.title(for: nil) == "Tick Step")
        #expect(!editor.canPerform(.tick, for: heading) && editor.canPerform(.tick, for: step))
        #expect(!editor.canPerform(.moveUp, for: heading) && editor.canPerform(.moveUp, for: step))
        #expect(!editor.canPerform(.moveDown, for: step))
        let items = editor.menu(for: step) { nil }?.items.filter { !$0.isSeparatorItem }
        #expect(
            items?.map(\.title) == [
                "Untick Step", "Make Heading", "Move Step Up", "Move Step Down", "Delete Step",
            ])
        #expect(items?.map(\.isEnabled) == [true, true, true, false, true])
        #expect(items?.first?.keyEquivalent == "U")
        // Making a ticked step a heading drops its tick.
        editor.toggleHeading(step, undoManager: nil)
        #expect(
            editor.step(step) == ChecklistStep(id: step, text: "Clean all parts", isHeading: true))
    }

    private static func undoManager() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }
}

struct ChecklistServiceTests {
    @Test
    func saveKeepsTheStepsInTheirOrderAndOnlyThoseWithText() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = ChecklistClock(now)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: clock.now))
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = ChecklistService(coordinator: coordinator)
        let ids = (0..<4).map { _ in UUID() }
        let saved = try await service.save(
            [
                ChecklistStep(id: ids[0], text: " Cleaning ", isHeading: true, isTicked: true),
                ChecklistStep(id: ids[1], text: "Clean all parts", isTicked: true),
                ChecklistStep(id: ids[2], text: "  "),
                ChecklistStep(id: ids[3], text: "Regulate"),
            ], for: job.id)
        #expect(saved.map(\.id) == [ids[0], ids[1], ids[3]] && saved.map(\.position) == [0, 1, 2])
        #expect(saved[0].text == "Cleaning" && saved[0].isHeading && !saved[0].isTicked)
        #expect(saved.allSatisfy { $0.createdAt == now && $0.updatedAt == now })
        // A move changes positions only. A step that did not change keeps its edit time.
        now = now.addingTimeInterval(60)
        clock.set(now)
        let moved = try await service.save(
            [
                ChecklistStep(id: ids[3], text: "Regulate on the timegrapher"),
                ChecklistStep(id: ids[1], text: "Clean all parts", isTicked: true),
            ], for: job.id)
        #expect(moved.map(\.id) == [ids[3], ids[1]] && moved.map(\.position) == [0, 1])
        #expect(moved[0].updatedAt == now && moved[1].updatedAt == saved[1].updatedAt)
        #expect(try await coordinator.read(ChecklistQueries.fetchAll) == moved)
        // A Done job takes changes. An archived one does not, and a step of another job is
        // refused.
        _ = try await JobService(coordinator: coordinator).setStage(job.id, to: .done)
        _ = try await service.save([ChecklistStep(id: ids[1], text: "Clean")], for: job.id)
        let other = try await JobTaskFixture.job(coordinator)
        await #expect(throws: ChecklistError.stepMismatch) {
            try await service.save([ChecklistStep(id: ids[1], text: "Clean")], for: other.id)
        }
        await #expect(throws: ChecklistError.stepMismatch) {
            try await service.save(
                [ChecklistStep(id: ids[0], text: "A"), ChecklistStep(id: ids[0], text: "B")],
                for: other.id)
        }
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: "UPDATE job SET archivedAt = 1 WHERE id = ?", arguments: [job.id.uuidString])
        }
        await #expect(throws: ArchiveError.archived) {
            try await service.save([], for: job.id)
        }
        #expect(try await coordinator.read(ChecklistQueries.fetchAll).map(\.text) == ["Clean"])
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func theJobPageChecklistSavesThroughTheLibraryAndShowsItsProgress() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let state = ChecklistState(service: ChecklistService(coordinator: coordinator))
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { !state.isLoading }
        #expect(state.progress(for: job.id).summary == "No steps yet")
        let editor = state.editor(for: job.id)
        let undo = UndoManager()
        undo.groupsByEvent = false
        let id = editor.addID
        editor.beginEditing(id)
        #expect(state.focusedStep?.id == nil && state.focusedJobID == job.id)
        type("Clean all parts", in: id, editor, undo)
        #expect(state.focusedStep?.id == id)
        act(undo) { editor.perform(.tick, for: id, undoManager: undo) }
        #expect(state.hasUnsavedChanges)
        #expect(await state.saveAll())
        editor.endEditing(id)
        #expect(state.focusedJobID == nil)
        try await waitUntil { state.records.count == 1 }
        #expect(state.records.first?.text == "Clean all parts" && state.records[0].isTicked)
        #expect(state.progress(for: job.id).summary == "1 of 1 done")
        // A failed save keeps the steps on the page and says so.
        try await JobTaskFixture.failWrites(coordinator, on: "checklistStep")
        act(undo) { editor.perform(.tick, for: id, undoManager: undo) }
        #expect(await !state.saveAll())
        #expect(editor.saveError != nil && editor.step(id)?.isTicked == false)
        try await JobTaskFixture.allowWrites(coordinator, on: "checklistStep")
        #expect(await state.saveAll())
        try await waitUntil { state.records.first?.isTicked == false }
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }
}

// Every list of steps a checklist saved.
final class SavedChecklists {
    nonisolated struct Failure: Error {}

    private(set) var lists: [[ChecklistStep]] = []
    var failure: (any Error)?
    var last: [ChecklistStep]? { lists.last }

    func save(_ steps: [ChecklistStep]) async throws {
        if let failure { throw failure }
        lists.append(steps)
    }
}

nonisolated final class ChecklistClock: Sendable {
    private let value: Mutex<Date>

    init(_ date: Date) { value = Mutex(date) }

    func set(_ date: Date) { value.withLock { $0 = date } }

    var now: @Sendable () -> Date { { self.value.withLock { $0 } } }
}

// Types keys at the end of a line as one burst, one change per key, as the field sends them.
// The field shows the line's text after each key, so a "# " that made a heading is gone.
private func type(
    _ keys: String, in id: UUID, _ editor: ChecklistEditor, _ undo: UndoManager
) {
    act(undo) {
        for key in keys {
            editor.change(id, to: (editor.step(id)?.text ?? "") + String(key), undoManager: undo)
        }
    }
}

// One key press, in its own Undo group, as the window's undo manager makes one per event.
private func act(_ undo: UndoManager, _ body: () -> Void) {
    undo.beginUndoGrouping()
    body()
    undo.endUndoGrouping()
}

// Moves the cursor where the editor asked, as the step's view does.
private func take(_ request: StepFocus?, in editor: ChecklistEditor, leaving id: UUID) -> UUID? {
    guard let request else { return nil }
    editor.endEditing(id)
    editor.beginEditing(request.id)
    editor.focusTaken(request.id)
    return request.id
}

private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ChecklistTimeout()
}

nonisolated private struct ChecklistTimeout: Error {}
