import Foundation
import Testing

@testable import Ure

// One test for each rule of the edit queue's design. Each rule comes from a group of review
// findings, listed in docs/planning/edit-queue-verification.md, and each test checks its rule in
// more than one way.
struct EditRuleTests {
    // The screen is what counts. A save that fails leaves the screen as it is, the next save sends
    // what the library still lacks, and an older change never saves over a later one.
    @Test(.timeLimit(.minutes(1)))
    func theScreenIsWhatSavesAfterAFailedSave() async throws {
        let clean = ChecklistStep(id: UUID(), text: "Clean")
        let oil = ChecklistStep(id: UUID(), text: "Oil")
        let checklist = try await ChecklistLibrary.make(steps: [clean, oil])
        let editor = checklist.editor

        // A tick that failed and was then taken back by hand leaves nothing unsaved.
        try await JobTaskFixture.failWrites(checklist.coordinator, on: "checklistStep")
        editor.toggleTick(clean.id, undoManager: nil)
        await checklist.queue.waitUntilIdle()
        #expect(editor.saveError != nil && editor.hasUnsavedChanges)
        editor.toggleTick(clean.id, undoManager: nil)
        await checklist.queue.waitUntilIdle()
        #expect(editor.saveError == nil && !editor.hasUnsavedChanges)

        // A tick that failed saves with the next change once writes work.
        editor.toggleTick(clean.id, undoManager: nil)
        await checklist.queue.waitUntilIdle()
        try await JobTaskFixture.allowWrites(checklist.coordinator, on: "checklistStep")
        editor.toggleTick(oil.id, undoManager: nil)
        await checklist.queue.waitUntilIdle()
        #expect(try await checklist.stored().map(\.isTicked) == [true, true])
        #expect(editor.saveError == nil && !editor.hasUnsavedChanges)

        // An untick that failed and typing in the same step save as the screen shows them.
        try await JobTaskFixture.failWrites(checklist.coordinator, on: "checklistStep")
        editor.toggleTick(oil.id, undoManager: nil)
        await checklist.queue.waitUntilIdle()
        try await JobTaskFixture.allowWrites(checklist.coordinator, on: "checklistStep")
        editor.beginEditing(oil.id)
        editor.change(oil.id, to: "Oil the escapement", undoManager: nil)
        editor.saveNow()
        await checklist.queue.waitUntilIdle()
        #expect(
            try await checklist.stored() == [
                ChecklistStep(id: clean.id, text: "Clean", isTicked: true),
                ChecklistStep(id: oil.id, text: "Oil the escapement"),
            ])
        editor.endEditing(oil.id)
        try await checklist.close()

        // A field works the same way: the text it shows is what saves.
        let notes = try await NotesLibrary.make(notes: "Saved", pause: PauseGate().pause)
        let field = notes.field
        try await JobTaskFixture.failWrites(notes.coordinator, on: "caliber")
        field.beginEditing()
        field.change(to: "Saved and typed", undoManager: nil)
        field.saveNow()
        await notes.queue.waitUntilIdle()
        #expect(field.saveError != nil && field.text == "Saved and typed")
        field.change(to: "Saved", undoManager: nil)
        field.saveNow()
        #expect(field.saveError == nil && !field.hasUnsavedChanges)
        try await JobTaskFixture.allowWrites(notes.coordinator, on: "caliber")
        field.change(to: "Saved, then more", undoManager: nil)
        field.saveNow()
        await notes.queue.waitUntilIdle()
        #expect(try await notes.stored() == "Saved, then more")
        try await notes.close()
    }

    // Each Undo step keeps what its own action did on screen. Undo puts back the screen as it was
    // before the action, and Redo as it was after, also when the action saved nothing.
    @Test(.timeLimit(.minutes(1)))
    func undoAndRedoPutBackWhatTheActionDidOnScreen() async throws {
        let gate = PauseGate()
        let step = ChecklistStep(id: UUID(), text: "Clean")
        let checklist = try await ChecklistLibrary.make(steps: [step], pause: gate.pause)
        let editor = checklist.editor
        let undo = UndoManager()
        undo.groupsByEvent = false

        // A space that saves as nothing, before and after the typing pause.
        editor.beginEditing(step.id)
        grouped(undo) { editor.change(step.id, to: "Clean ", undoManager: undo) }
        undo.undo()
        #expect(editor.step(step.id)?.text == "Clean")
        undo.redo()
        #expect(editor.step(step.id)?.text == "Clean ")
        undo.undo()
        grouped(undo) { editor.change(step.id, to: "Clean ", undoManager: undo) }
        try await gate.elapse()
        try await Task.sleep(for: .milliseconds(100))
        undo.undo()
        #expect(editor.step(step.id)?.text == "Clean")
        editor.endEditing(step.id)

        // A heading typed in the row that adds a step goes with ⌘Z and comes back with ⇧⌘Z.
        let add = editor.addID
        editor.beginEditing(add)
        grouped(undo) { editor.change(add, to: "# Assembly", undoManager: undo) }
        editor.endEditing(add)
        await checklist.queue.waitUntilIdle()
        undo.undo()
        await checklist.queue.waitUntilIdle()
        #expect(editor.steps.map(\.id) == [step.id])
        #expect(try await checklist.stored() == [step])
        undo.redo()
        await checklist.queue.waitUntilIdle()
        let heading = ChecklistStep(id: add, text: "Assembly", isHeading: true)
        #expect(editor.steps == [step, heading])
        #expect(try await checklist.stored() == [step, heading])

        // A tick that failed goes from the screen with ⌘Z, and ⇧⌘Z brings it back and saves it.
        try await JobTaskFixture.failWrites(checklist.coordinator, on: "checklistStep")
        grouped(undo) { editor.toggleTick(step.id, undoManager: undo) }
        await checklist.queue.waitUntilIdle()
        undo.undo()
        await checklist.queue.waitUntilIdle()
        #expect(editor.step(step.id)?.isTicked == false && editor.saveError == nil)
        try await JobTaskFixture.allowWrites(checklist.coordinator, on: "checklistStep")
        undo.redo()
        await checklist.queue.waitUntilIdle()
        #expect(editor.step(step.id)?.isTicked == true)
        #expect(try await checklist.stored().first?.isTicked == true)
        try await checklist.close()
    }

    // An Undo or Redo is an edit like any other. It shows at once and then saves through the
    // queue, after every edit before it.
    @Test(.timeLimit(.minutes(1)))
    func undoShowsAtOnceAndSavesAfterTheEditsBeforeIt() async throws {
        // A field: ⌘Z and ⇧⌘Z while its save waits show at once and save in order.
        let notes = try await NotesLibrary.make(notes: "Saved", pause: PauseGate().pause)
        let field = notes.field
        let undo = UndoManager()
        undo.groupsByEvent = false
        field.beginEditing()
        grouped(undo) { field.change(to: "Typed", undoManager: undo) }
        var (hold, holding) = try await LibraryHold.start(on: notes.coordinator)
        field.saveNow()
        undo.undo()
        #expect(field.text == "Saved")
        undo.redo()
        #expect(field.text == "Typed")
        undo.undo()
        hold.release()
        _ = try await holding.value
        await notes.queue.waitUntilIdle()
        #expect(try await notes.stored() == "Saved" && field.text == "Saved")
        try await notes.close()

        // A checklist and a record command: their changes and Undos run in the order you made
        // them, also while the library is held.
        let step = ChecklistStep(id: UUID(), text: "Clean")
        let checklist = try await ChecklistLibrary.make(steps: [step])
        let editor = checklist.editor
        let watch = try await WatchService(coordinator: checklist.coordinator)
            .create(named: "Seamaster")
        (hold, holding) = try await LibraryHold.start(on: checklist.coordinator)
        grouped(undo) { editor.toggleTick(step.id, undoManager: undo) }
        grouped(undo) {
            checklist.queue.submit(
                .watch(.archive(watch.id, true)), in: .watches, undo: "Archive Watch",
                undoManager: undo)
        }
        undo.undo()
        undo.undo()
        #expect(editor.step(step.id)?.isTicked == false)
        hold.release()
        _ = try await holding.value
        await checklist.queue.waitUntilIdle()
        #expect(try await checklist.stored() == [step])
        let archived = try await checklist.coordinator.read {
            try WatchQueries.fetch(watch.id, in: $0)
        }?.archivedAt
        #expect(archived == nil && checklist.queue.failures.isEmpty)
        try await checklist.close()
    }

    // One action is one Undo step, registered when you act. A later action never reuses it, also
    // after a failed save.
    @Test(.timeLimit(.minutes(1)))
    func eachActionIsItsOwnUndoStep() async throws {
        // A field: typing, Esc, failed typing and the typing after it are four steps.
        let notes = try await NotesLibrary.make(notes: "Saved", pause: PauseGate().pause)
        let field = notes.field
        let undo = UndoManager()
        undo.groupsByEvent = false
        field.beginEditing()
        grouped(undo) { field.change(to: "First", undoManager: undo) }
        field.saveNow()
        grouped(undo) { field.revert(undoManager: undo) }
        await notes.queue.waitUntilIdle()
        try await JobTaskFixture.failWrites(notes.coordinator, on: "caliber")
        grouped(undo) { field.change(to: "Second", undoManager: undo) }
        field.saveNow()
        await notes.queue.waitUntilIdle()
        try await JobTaskFixture.allowWrites(notes.coordinator, on: "caliber")
        grouped(undo) { field.change(to: "Second, then more", undoManager: undo) }
        field.saveNow()
        await notes.queue.waitUntilIdle()
        var shown: [String] = []
        while undo.canUndo {
            undo.undo()
            await notes.queue.waitUntilIdle()
            shown.append(field.text)
        }
        #expect(shown == ["Second", "Saved", "First", "Saved"])
        #expect(try await notes.stored() == "Saved")
        try await notes.close()

        // A checklist: a tick that failed, Try Again, and typing after it are two steps.
        let step = ChecklistStep(id: UUID(), text: "Clean")
        let checklist = try await ChecklistLibrary.make(steps: [step])
        let editor = checklist.editor
        try await JobTaskFixture.failWrites(checklist.coordinator, on: "checklistStep")
        grouped(undo) { editor.toggleTick(step.id, undoManager: undo) }
        await checklist.queue.waitUntilIdle()
        try await JobTaskFixture.allowWrites(checklist.coordinator, on: "checklistStep")
        editor.saveNow()
        editor.beginEditing(step.id)
        grouped(undo) { editor.change(step.id, to: "Clean all parts", undoManager: undo) }
        editor.endEditing(step.id)
        await checklist.queue.waitUntilIdle()
        undo.undo()
        await checklist.queue.waitUntilIdle()
        #expect(
            try await checklist.stored() == [
                ChecklistStep(id: step.id, text: "Clean", isTicked: true)
            ])
        undo.undo()
        await checklist.queue.waitUntilIdle()
        #expect(try await checklist.stored() == [step] && !undo.canUndo)
        try await checklist.close()
    }

    // The queue and the owners keep what an Undo step needs exactly as long as the undo manager
    // holds the step. Undo uses a step up, and a new action drops the Redo steps, also while
    // their saves wait.
    @Test(.timeLimit(.minutes(1)))
    func whatAStepNeedsGoesWithTheStep() async throws {
        let notes = try await NotesLibrary.make(notes: "Saved", pause: PauseGate().pause)
        let field = notes.field
        let undo = UndoManager()
        undo.groupsByEvent = false
        field.beginEditing()
        for text in ["One", "Two"] {
            grouped(undo) { field.change(to: text, undoManager: undo) }
            field.saveNow()
        }
        await notes.queue.waitUntilIdle()
        undo.undo()
        undo.undo()
        grouped(undo) { field.change(to: "Three", undoManager: undo) }
        field.saveNow()
        await notes.queue.waitUntilIdle()
        #expect(notes.queue.keptUndoCount == 1)

        let (hold, holding) = try await LibraryHold.start(on: notes.coordinator)
        grouped(undo) { field.change(to: "Four", undoManager: undo) }
        field.saveNow()
        undo.undo()
        grouped(undo) { field.change(to: "Five", undoManager: undo) }
        field.saveNow()
        hold.release()
        _ = try await holding.value
        await notes.queue.waitUntilIdle()
        #expect(notes.queue.keptUndoCount == 2 && !undo.canRedo)
        try await notes.close()

        let step = ChecklistStep(id: UUID(), text: "Clean")
        let checklist = try await ChecklistLibrary.make(steps: [step])
        let editor = checklist.editor
        grouped(undo) { editor.toggleTick(step.id, undoManager: undo) }
        await checklist.queue.waitUntilIdle()
        undo.undo()
        grouped(undo) { editor.toggleHeading(step.id, undoManager: undo) }
        await checklist.queue.waitUntilIdle()
        #expect(checklist.queue.keptUndoCount == 1 && !undo.canRedo)
        try await checklist.close()
    }

    // An Undo that fails is reported like any failed edit, and Try Again runs it once more. Redo
    // after it does nothing, because the change still holds, and leaves nothing to try again.
    @Test(.timeLimit(.minutes(1)))
    func anUndoThatFailsIsReportedAndCanBeTriedAgain() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await WatchService(coordinator: coordinator).create(named: "Seamaster")
        let queue = EditQueue(coordinator: coordinator)
        let undo = UndoManager()
        undo.groupsByEvent = false
        func archived() async throws -> Bool {
            try await coordinator.read { try WatchQueries.fetch(watch.id, in: $0) }?.archivedAt
                != nil
        }
        grouped(undo) {
            queue.submit(
                .watch(.archive(watch.id, true)), in: .watches, undo: "Archive Watch",
                undoManager: undo)
        }
        await queue.waitUntilIdle()

        try await JobTaskFixture.failWrites(coordinator, on: "watch")
        undo.undo()
        await queue.waitUntilIdle()
        #expect(queue.failure(in: .watches) != nil)
        #expect(try await archived())
        try await JobTaskFixture.allowWrites(coordinator, on: "watch")
        #expect(queue.retryUndo(in: .watches))
        await queue.waitUntilIdle()
        #expect(queue.failure(in: .watches) == nil)
        #expect(try await archived() == false)

        undo.redo()
        await queue.waitUntilIdle()
        try await JobTaskFixture.failWrites(coordinator, on: "watch")
        undo.undo()
        await queue.waitUntilIdle()
        #expect(queue.failure(in: .watches) != nil)
        try await JobTaskFixture.allowWrites(coordinator, on: "watch")
        undo.redo()
        await queue.waitUntilIdle()
        #expect(!queue.retryUndo(in: .watches))
        #expect(try await archived())
        undo.undo()
        await queue.waitUntilIdle()
        #expect(try await archived() == false)
        try await coordinator.close()
    }

    // The test host turns off undo grouping by event, so each action opens its own group, as a
    // key press does in the app.
    private func grouped(_ undo: UndoManager, _ action: () -> Void) {
        undo.beginUndoGrouping()
        action()
        undo.endUndoGrouping()
    }
}
