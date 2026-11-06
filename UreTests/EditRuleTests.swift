import Foundation
import GRDB
import Testing

@testable import Ure

// Tests of the six rules of the edit queue's design, with the queue stopping at the first failed
// save. Each rule comes from a group of review findings, listed in
// docs/planning/edit-queue-verification.md, and each test checks its rule in more than one way.
struct EditRuleTests {
    // Rule 1: the library never falls behind. Edits run one at a time, in the order you made
    // them, and none runs past a failed one. Try Again while the library still refuses keeps the
    // queue stopped, and the next Try Again runs the failed edit and then every edit after it.
    @Test(.timeLimit(.minutes(1)))
    func noEditRunsPastAFailedOne() async throws {
        // A checklist: a tick fails, and an untick, a move and typing wait behind it.
        let clean = ChecklistStep(id: UUID(), text: "Clean")
        let oil = ChecklistStep(id: UUID(), text: "Oil")
        let checklist = try await ChecklistLibrary.make(steps: [clean, oil])
        let editor = checklist.editor
        try await JobTaskFixture.failWrites(checklist.coordinator, on: "checklistStep")
        editor.toggleTick(clean.id, undoManager: nil)
        #expect(await checklist.queue.waitUntilStopped())
        editor.toggleTick(clean.id, undoManager: nil)
        editor.move(oil.id, by: -1, undoManager: nil)
        editor.beginEditing(oil.id)
        editor.change(oil.id, to: "Oil the escapement", undoManager: nil)
        editor.endEditing(oil.id)
        #expect(try await checklist.stored() == [clean, oil])
        checklist.queue.retry()
        #expect(await checklist.queue.waitUntilStopped())
        #expect(try await checklist.stored() == [clean, oil])
        try await JobTaskFixture.allowWrites(checklist.coordinator, on: "checklistStep")
        checklist.queue.retry()
        #expect(await !checklist.queue.waitUntilStopped())
        let typed = ChecklistStep(id: oil.id, text: "Oil the escapement")
        #expect(try await checklist.stored() == [typed, clean])
        #expect(editor.steps == [typed, clean] && !editor.hasUnsavedChanges)
        try await checklist.close()

        // Notes that fail, and an archive after them: the archive waits, so the notes save
        // before the record is archived.
        let notes = try await NotesLibrary.make(notes: "Saved", pause: PauseGate().pause)
        try await JobTaskFixture.failWrites(notes.coordinator, on: "caliber")
        notes.field.beginEditing()
        notes.field.change(to: "Lift angle 52°", undoManager: nil)
        notes.field.endEditing()
        let archiving = notes.queue.submit(
            .caliber(.archive(notes.caliberID, true)), in: .calibers)
        #expect(await notes.queue.waitUntilStopped())
        #expect(archiving.isPending && notes.queue.isBusy)
        try await JobTaskFixture.allowWrites(notes.coordinator, on: "caliber")
        notes.queue.retry()
        #expect(await archiving.saved)
        #expect(try await notes.stored() == "Lift angle 52°")
        try await notes.close()
    }

    // Rule 1 also holds for several moves that wait: once they run, the library has the order
    // the screen shows. Each move is worked out from the order the moves before it leave.
    @Test(.timeLimit(.minutes(1)))
    func movesThatWaitSaveTheOrderTheScreenShows() async throws {
        let steps = ["A", "B", "C", "D"].map { ChecklistStep(id: UUID(), text: $0) }
        let checklist = try await ChecklistLibrary.make(steps: steps)
        let editor = checklist.editor
        try await JobTaskFixture.failWrites(checklist.coordinator, on: "checklistStep")
        for id in [steps[2].id, steps[2].id, steps[3].id, steps[3].id] {
            editor.move(id, by: -1, undoManager: nil)
        }
        #expect(editor.steps.map(\.text) == ["C", "D", "A", "B"])
        #expect(await checklist.queue.waitUntilStopped())
        try await JobTaskFixture.allowWrites(checklist.coordinator, on: "checklistStep")
        checklist.queue.retry()
        #expect(await !checklist.queue.waitUntilStopped())
        #expect(try await checklist.stored().map(\.text) == ["C", "D", "A", "B"])
        try await checklist.close()

        // The changes between any two orders of four steps, also with a step added and one
        // taken away, give exactly the new order.
        let added = ChecklistStep(id: UUID(), text: "E")
        for order in permutations(of: steps) {
            for new in [order, Array(order.dropLast()) + [added]] {
                let changes = ChecklistOperation.changes(from: steps, to: new)
                #expect(ChecklistOperation.applying(changes, to: steps).steps == new)
            }
        }
    }

    // Rule 2 also means that a field or the checklist shows its Undo at once, as the action
    // showed on screen, and Redo as it was after, also when the action saved nothing.
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

        // A tick that failed goes from the screen with ⌘Z at once, and ⇧⌘Z brings it back. Both
        // wait behind the tick, and Try Again saves all three in order.
        try await JobTaskFixture.failWrites(checklist.coordinator, on: "checklistStep")
        grouped(undo) { editor.toggleTick(step.id, undoManager: undo) }
        #expect(await checklist.queue.waitUntilStopped())
        undo.undo()
        #expect(editor.step(step.id)?.isTicked == false)
        try await JobTaskFixture.allowWrites(checklist.coordinator, on: "checklistStep")
        undo.redo()
        checklist.queue.retry()
        #expect(await !checklist.queue.waitUntilStopped())
        #expect(editor.step(step.id)?.isTicked == true)
        #expect(try await checklist.stored().first?.isTicked == true)
        try await checklist.close()
    }

    // Rule 2 also means that an Undo or Redo is an edit like any other. It shows at once and then
    // saves through the queue, after every edit before it.
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
        #expect(archived == nil && checklist.queue.failure == nil)
        try await checklist.close()
    }

    // Rule 3: one action is one Undo step, registered when you act. A later action never reuses
    // it, also after a failed save.
    @Test(.timeLimit(.minutes(1)))
    func eachActionIsItsOwnUndoStep() async throws {
        // A field: typing, Esc, typing whose save failed and the typing after it are four steps.
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
        #expect(await notes.queue.waitUntilStopped())
        try await JobTaskFixture.allowWrites(notes.coordinator, on: "caliber")
        grouped(undo) { field.change(to: "Second, then more", undoManager: undo) }
        field.saveNow()
        notes.queue.retry()
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
        #expect(await checklist.queue.waitUntilStopped())
        try await JobTaskFixture.allowWrites(checklist.coordinator, on: "checklistStep")
        checklist.queue.retry()
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

    // Rule 4: the queue and the owners keep what an Undo step needs only while the undo manager
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

    // Rule 5: a failure shows in one place, with Try Again and Discard Unsaved Changes, and
    // nothing unsaved goes without asking. Discard drops the failed edit and every edit that
    // waits, each field and checklist shows what the library holds, and Undo starts over.
    @Test(.timeLimit(.minutes(1)))
    func discardDropsEveryChangeThatDidNotSaveAndStartsUndoOver() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let editing = EditingFixture.make(coordinator, pause: PauseGate().pause)
        let observations = [
            Task { await editing.jobs.observe() }, Task { await editing.parts.observe() },
            Task { await editing.checklist.observe() },
        ]
        defer { observations.forEach { $0.cancel() } }
        try await waitUntil {
            !editing.jobs.isLoading && !editing.parts.isLoading && !editing.checklist.isLoading
        }
        let undo = UndoManager()
        undo.groupsByEvent = false
        let title = try #require(editing.jobs.facts(for: job.id)?.title)
        grouped(undo) { title.change(to: "Saved title", undoManager: undo) }
        title.saveNow()
        await editing.queue.waitUntilIdle()

        // The job's title fails, and a part, a checklist step and more typing wait or stay on
        // screen.
        try await JobTaskFixture.failWrites(coordinator, on: "job")
        title.beginEditing()
        grouped(undo) { title.change(to: "Failed title", undoManager: undo) }
        title.saveNow()
        var adding: EditTicket?
        grouped(undo) {
            adding = editing.parts.add(named: "Crystal", to: job.id, undoManager: undo)
        }
        let editor = editing.checklist.editor(for: job.id)
        let step = editor.addID
        editor.beginEditing(step)
        grouped(undo) { editor.change(step, to: "Clean all parts", undoManager: undo) }
        #expect(await editing.saveAllFields() == .stopped)
        // The bar says what went wrong in words, never in SQL. The help tag keeps the details.
        #expect(editing.failure == "The library couldn’t be written to.")
        #expect(editing.queue.failureDetails?.contains("fixture disk failure") == true)
        #expect(
            EditQueue.reason(for: DatabaseError(resultCode: .SQLITE_FULL)) == "The disk is full.")
        #expect(
            EditQueue.reason(for: ArchiveError.archived)
                == ArchiveError.archived.localizedDescription)
        grouped(undo) { title.change(to: "Failed title, then more", undoManager: undo) }
        #expect(editing.hasUnsavedFields && undo.canUndo)

        editing.discardUnsaved()
        #expect(editing.failure == nil && editing.queue.isIdle && !editing.hasUnsavedFields)
        #expect(title.text == "Saved title" && editor.steps.isEmpty)
        #expect(await !adding.didSave)
        #expect(!undo.canUndo && !undo.canRedo)
        try await JobTaskFixture.allowWrites(coordinator, on: "job")
        #expect(
            try await coordinator.read { try JobQueries.fetch(job.id, in: $0) }?.title
                == "Saved title")
        #expect(try await coordinator.read { try PartQueries.fetchAll($0) }.isEmpty)

        // The queue runs again: the next change saves at once.
        title.change(to: "After discard", undoManager: nil)
        title.endEditing()
        await editing.queue.waitUntilIdle()
        #expect(
            try await coordinator.read { try JobQueries.fetch(job.id, in: $0) }?.title
                == "After discard")
        observations.forEach { $0.cancel() }
        for observation in observations { await observation.value }
        try await coordinator.close()
    }

    // Rule 5 also covers leaving: quitting and closing the window while a save failed ask, and
    // try again, discard or stay as you choose. A backup is never made without the changes.
    @Test(.timeLimit(.minutes(1)))
    func quittingClosingAndExportingAskWhileASaveFailed() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owners = try await NoteFixture.owners(coordinator)
        let editing = EditingFixture.make(coordinator, pause: PauseGate().pause)
        await editing.notes.load(owners[0])
        let notes = try #require(editing.notes.field(for: owners[0]))
        let service = RecordNotesService(coordinator: coordinator)
        try await JobTaskFixture.failWrites(coordinator, on: "watch")
        notes.change(to: "Typed before quitting", undoManager: nil)

        // Stay keeps the app open and the change waiting.
        var asked: [String] = []
        let stays = await UnsavedChanges.save(editing, toQuit: true) { failure in
            asked.append(failure)
            return .stay
        }
        #expect(!stays && asked.count == 1 && editing.failure != nil)

        // A backup is not made while the change waits.
        let backup = BackupState(coordinator: coordinator, editing: editing)
        await backup.refresh()
        backup.chooseDestination()
        #expect(backup.errorMessage == BackupState.unsavedChanges && !backup.isExporting)

        // Try Again while writes still fail asks once more. Once writes work, Try Again saves the
        // change and the window closes.
        var answers: [UnsavedChanges.Choice] = [.tryAgain, .stay]
        let staysAgain = await UnsavedChanges.save(editing, toQuit: false) { _ in
            answers.removeFirst()
        }
        #expect(!staysAgain && answers.isEmpty && editing.failure != nil)
        try await JobTaskFixture.allowWrites(coordinator, on: "watch")
        let closes = await UnsavedChanges.save(editing, toQuit: false) { _ in .tryAgain }
        #expect(closes && editing.failure == nil)
        #expect(try await service.text(for: owners[0]) == "Typed before quitting")

        // Discard quits without the change.
        try await JobTaskFixture.failWrites(coordinator, on: "watch")
        notes.change(to: "Discarded", undoManager: nil)
        let discards = await UnsavedChanges.save(editing, toQuit: true) { _ in .discard }
        #expect(discards && notes.text == "Typed before quitting")
        #expect(try await service.text(for: owners[0]) == "Typed before quitting")
        try await JobTaskFixture.allowWrites(coordinator, on: "watch")
        try await coordinator.close()
    }

    // Rule 5 also covers typing done while quitting or closing waits: it saves too, so the app
    // goes ahead only once nothing that can save is left.
    @Test(.timeLimit(.minutes(1)))
    func savingEverythingSavesTypingDoneWhileItWaits() async throws {
        let library = try await NotesLibrary.make(notes: "Saved", pause: PauseGate().pause)
        let field = library.field
        field.beginEditing()
        let (hold, holding) = try await LibraryHold.start(on: library.coordinator)
        library.queue.submit(
            .caliber(.set(library.caliberID, .maker("Omega"))), in: .calibers)
        let saving = Task { await library.queue.saveEverything() }
        try await Task.sleep(for: .milliseconds(50))
        field.change(to: "Typed while closing", undoManager: nil)
        hold.release()
        _ = try await holding.value
        #expect(await saving.value == .saved)
        #expect(try await library.stored() == "Typed while closing")
        try await library.close()
    }

    // Rule 5 also covers changes the app makes on its own: a job being set up goes only when
    // nothing is in it, and a title cleared on screen, which can't save, keeps the job.
    @Test(.timeLimit(.minutes(1)))
    func aJobWithTextThatCantSaveIsNotThrownAway() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await WatchService(coordinator: coordinator).create(named: "Ventura")
        let open = try await JobService(coordinator: coordinator).start(
            for: watch.id, title: "Full service")
        let editing = EditingFixture.make(coordinator, pause: PauseGate().pause)
        let jobs = editing.jobs
        let observations = [
            Task { await jobs.observe() }, Task { await editing.watches.observe() },
        ]
        defer { observations.forEach { $0.cancel() } }
        try await waitUntil { !jobs.isLoading && !editing.watches.isLoading }
        func stored(_ id: UUID) async throws -> JobRecord? {
            try await coordinator.read { try JobQueries.fetch(id, in: $0) }
        }

        // A job with a cleared title stays, with the title it had in the library.
        #expect(await jobs.create().didSave)
        let cleared = try #require(jobs.selectedID)
        let title = try #require(jobs.facts(for: cleared)?.title)
        title.beginEditing()
        title.change(to: "", undoManager: nil)
        #expect(jobs.openOpenJob(of: watch.id, discardingBlank: cleared)?.id == open.id)
        await editing.queue.waitUntilIdle()
        #expect(try await stored(cleared) != nil)
        title.endEditing()

        // A job with nothing in it goes.
        #expect(await jobs.create().didSave)
        let blank = try #require(jobs.selectedID)
        #expect(jobs.openOpenJob(of: watch.id, discardingBlank: blank)?.id == open.id)
        await editing.queue.waitUntilIdle()
        #expect(try await stored(blank) == nil)
        observations.forEach { $0.cancel() }
        for observation in observations { await observation.value }
        try await coordinator.close()
    }

    // Rule 6: while the queue is stopped and a change waits that the screen does not show yet,
    // such as a deletion or an archive, no record page takes edits. During normal saving there is
    // no hold, so a field keeps the cursor while a command saves.
    @Test(.timeLimit(.minutes(1)))
    func recordPagesTakeNoEditsWhileACommandWaitsBehindAFailure() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let watchID = try #require(job.watchID)
        let caliber = try await CaliberService(coordinator: coordinator).create(named: "552")
        let editing = EditingFixture.make(coordinator, pause: PauseGate().pause)
        let observations = [
            Task { await editing.watches.observe() }, Task { await editing.jobs.observe() },
            Task { await editing.parts.observe() }, Task { await editing.calibers.observe() },
        ]
        defer { observations.forEach { $0.cancel() } }
        try await waitUntil {
            !editing.watches.isLoading && !editing.jobs.isLoading && !editing.parts.isLoading
                && !editing.calibers.isLoading
        }
        let part = try #require(await editing.parts.add(named: "Mainspring", to: job.id)?.part)
        func pagesTakeEdits() -> [Bool] {
            [
                editing.canWrite(.watch(watchID)), editing.canWrite(.job(job.id)),
                editing.canWrite(.caliber(caliber.id)), editing.canWrite(part),
            ]
        }

        // Normal saving: a command waits behind a slow write, and every page takes edits.
        let (hold, holding) = try await LibraryHold.start(on: coordinator)
        editing.jobs.open(job)
        #expect(editing.jobs.setStage(.waiting) != nil)
        #expect(editing.queue.isBusy && !editing.queue.isStopped)
        #expect(pagesTakeEdits() == [true, true, true, true])
        hold.release()
        _ = try await holding.value
        await editing.queue.waitUntilIdle()

        // A failed save with only typing behind it holds nothing, because typing shows.
        try await JobTaskFixture.failWrites(coordinator, on: "job")
        let title = try #require(editing.jobs.facts(for: job.id)?.title)
        title.beginEditing()
        title.change(to: "Overhaul", undoManager: nil)
        title.endEditing()
        #expect(await editing.queue.waitUntilStopped())
        #expect(pagesTakeEdits() == [true, true, true, true])

        // A deletion and an archive wait behind it, and then no page takes edits.
        #expect(editing.parts.remove(part.id) != nil)
        editing.watches.select(watchID)
        #expect(editing.watches.toggleArchive() != nil)
        #expect(pagesTakeEdits() == [false, false, false, false] && editing.isSaving)

        try await JobTaskFixture.allowWrites(coordinator, on: "job")
        editing.tryAgain()
        #expect(await !editing.queue.waitUntilStopped())
        #expect(editing.canWrite(.job(job.id)) && editing.canWrite(.caliber(caliber.id)))
        #expect(editing.parts.part(part.id) == nil)
        #expect(
            try await coordinator.read { try JobQueries.fetch(job.id, in: $0) }?.title == "Overhaul"
        )
        observations.forEach { $0.cancel() }
        for observation in observations { await observation.value }
        try await coordinator.close()
    }

    // Rule 6 also covers normal saving: an edit that could fail for good when its turn comes is
    // refused when you act. While a record's deletion or archive waits or runs, even when it
    // saves slowly or runs again after Try Again, that record takes no edits, and a spare whose
    // use waits is offered to no other line. Every other record keeps taking edits.
    @Test(.timeLimit(.minutes(1)))
    func aRecordTakesNoEditsWhileItsDeletionOrArchiveSaves() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let watchID = try #require(job.watchID)
        let other = try await WatchService(coordinator: coordinator).create(named: "Ventura")
        let caliber = try await CaliberService(coordinator: coordinator).create(named: "552")
        let service = PartService(coordinator: coordinator)
        let mainspring = try await service.add(named: "Mainspring", to: job.id)
        let crystal = try await service.add(named: "Crystal", to: job.id)
        let spare = try await service.add(named: "Spare crystal", to: nil)
        let link = try await MaterialService(coordinator: coordinator).addLink(
            try #require(URL(string: "https://example.org")), for: .watch(other.id))
        let editing = EditingFixture.make(coordinator, pause: PauseGate().pause)
        let observations = [
            Task { await editing.watches.observe() }, Task { await editing.jobs.observe() },
            Task { await editing.parts.observe() }, Task { await editing.calibers.observe() },
            Task { await editing.material.observe() },
        ]
        defer { observations.forEach { $0.cancel() } }
        try await waitUntil {
            !editing.watches.isLoading && !editing.jobs.isLoading && !editing.parts.isLoading
                && !editing.calibers.isLoading && editing.material.records.count == 1
        }
        let parts = editing.parts
        let queue = editing.queue
        let linkRecord = try #require(editing.material.records.first)

        // A deletion, an archive, a material removal and a spare's use save slowly.
        var (hold, holding) = try await LibraryHold.start(on: coordinator)
        #expect(parts.remove(mainspring.id) != nil)
        editing.watches.select(watchID)
        #expect(editing.watches.toggleArchive() != nil)
        #expect(editing.material.remove(linkRecord, on: .watch(other.id), undoManager: nil) != nil)
        #expect(parts.useSpare(spare.id, on: job.id) != nil)
        #expect(queue.isBusy && !queue.isStopped)
        // The records that end take no edits, and their commands refuse at once.
        #expect(!editing.canWrite(mainspring) && !editing.canWrite(.watch(watchID)))
        #expect(queue.isEnding(.material(link.id)))
        #expect(parts.advance(mainspring.id) == nil && parts.remove(mainspring.id) == nil)
        // The spare is offered to no other line and can't be used twice.
        #expect(parts.spares(matching: "Spare").isEmpty)
        #expect(parts.useSpare(spare.id, on: job.id) == nil)
        // Every other record still takes edits, the part's own job among them.
        #expect(editing.canWrite(crystal) && editing.canWrite(.job(job.id)))
        #expect(editing.canWrite(.watch(other.id)) && editing.canWrite(.caliber(caliber.id)))
        hold.release()
        _ = try await holding.value
        await queue.waitUntilIdle()
        #expect(queue.failure == nil && parts.part(mainspring.id) == nil)
        #expect(parts.part(spare.id)?.jobID == job.id)

        // Right after Try Again, the deletion runs again while the queue is no longer stopped,
        // and its part still takes no edits.
        try await JobTaskFixture.failWrites(coordinator, on: "job")
        let title = try #require(editing.jobs.facts(for: job.id)?.title)
        title.beginEditing()
        title.change(to: "Overhaul", undoManager: nil)
        title.endEditing()
        #expect(await queue.waitUntilStopped())
        #expect(parts.remove(crystal.id) != nil)
        try await JobTaskFixture.allowWrites(coordinator, on: "job")
        (hold, holding) = try await LibraryHold.start(on: coordinator)
        editing.tryAgain()
        #expect(!queue.isStopped && !queue.holdsRecords)
        #expect(!editing.canWrite(crystal) && editing.canWrite(.job(job.id)))
        hold.release()
        _ = try await holding.value
        await queue.waitUntilIdle()
        #expect(queue.failure == nil && parts.part(crystal.id) == nil)
        observations.forEach { $0.cancel() }
        for observation in observations { await observation.value }
        try await coordinator.close()
    }

    // Rule 6 also covers a spare that Redo puts back on a job: while that waits or runs, the
    // spare is offered to no other line, so it is never used twice.
    @Test(.timeLimit(.minutes(1)))
    func aSpareThatRedoPutsBackOnAJobIsNotOfferedAgain() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let spare = try await PartService(coordinator: coordinator).add(
            named: "Spare crystal", to: nil)
        let editing = EditingFixture.make(coordinator, pause: PauseGate().pause)
        let parts = editing.parts
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { !parts.isLoading }
        let undo = UndoManager()
        undo.groupsByEvent = false
        grouped(undo) { parts.useSpare(spare.id, on: job.id, undoManager: undo) }
        await editing.queue.waitUntilIdle()
        undo.undo()
        await editing.queue.waitUntilIdle()
        #expect(parts.part(spare.id)?.jobID == nil)
        #expect(parts.spares(matching: "Spare").map(\.id) == [spare.id])

        let (hold, holding) = try await LibraryHold.start(on: coordinator)
        undo.redo()
        #expect(parts.spares(matching: "Spare").isEmpty)
        #expect(parts.useSpare(spare.id, on: job.id) == nil)
        hold.release()
        _ = try await holding.value
        await editing.queue.waitUntilIdle()
        #expect(parts.part(spare.id)?.jobID == job.id && editing.queue.failure == nil)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    // Rule 6 can't refuse an Undo or Redo when you act: AppKit takes the step when you press ⌘Z,
    // and a change without an Undo step of its own, such as Start Job or a blank job that goes,
    // can come after it. So a rule that refuses an Undo or Redo when its turn comes skips it. It
    // changed nothing, its message shows on the record's page, and the queue goes on. A disk
    // error in an Undo still stops the queue, as undoComesFromTheStoredDataAlsoAfterAFailedSave
    // shows.
    @Test(.timeLimit(.minutes(1)))
    func anUndoOrRedoThatARuleRefusesIsSkipped() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let first = try await JobTaskFixture.job(coordinator)
        let watchID = try #require(first.watchID)
        let editing = EditingFixture.make(coordinator, pause: PauseGate().pause)
        let jobs = editing.jobs
        let observation = Task { await jobs.observe() }
        defer { observation.cancel() }
        try await waitUntil { !jobs.isLoading }
        func stage(_ id: UUID) async throws -> JobStage? {
            try await coordinator.read { try JobQueries.fetch(id, in: $0) }?.stage
        }

        // The first job is Done, and a second job starts on the same watch. ⌘Z of Done can't
        // reopen the first job while the second is open.
        let undo = UndoManager()
        undo.groupsByEvent = false
        jobs.open(first)
        grouped(undo) { jobs.setStage(.done, undoManager: undo) }
        await editing.queue.waitUntilIdle()
        #expect(await jobs.start(for: watchID)?.saved == true)
        let second = try #require(jobs.selectedID)
        undo.undo()
        await editing.queue.waitUntilIdle()
        #expect(editing.failure == nil && editing.queue.isIdle)
        #expect(try await stage(first.id) == .done)
        #expect(try await stage(second) == .inProgress)
        #expect(jobs.refusal?.hasPrefix("Nothing was undone. This watch already has") == true)

        // The queue goes on, and it keeps nothing for the skipped step.
        grouped(undo) { jobs.setStage(.done, undoManager: undo) }
        await editing.queue.waitUntilIdle()
        #expect(try await stage(second) == .done)
        #expect(jobs.refusal == nil && editing.queue.keptUndoCount == 1)

        // A blank job's notes: typed, undone, and then the blank job goes. ⇧⌘Z can't put the
        // notes back on a job that is gone. The notes field shows what the library holds, and the
        // message shows on the job page.
        #expect(await jobs.create()?.saved == true)
        let blank = try #require(jobs.selectedID)
        await editing.notes.load(.job(blank))
        let notes = try #require(editing.notes.field(for: .job(blank)))
        let redo = UndoManager()
        redo.groupsByEvent = false
        notes.beginEditing()
        grouped(redo) { notes.change(to: "Check the crown", undoManager: redo) }
        notes.endEditing()
        redo.undo()
        await editing.queue.waitUntilIdle()
        #expect(notes.text.isEmpty)
        #expect(await editing.queue.submit(.job(.discardIfBlank(blank)), in: .jobs).saved)
        #expect(try await stage(blank) == nil)
        redo.redo()
        await editing.queue.waitUntilIdle()
        #expect(editing.failure == nil && editing.queue.isIdle && notes.text.isEmpty)
        #expect(jobs.refusal == "Nothing was redone. This job is no longer available.")
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    // Rule 2 also holds when the field that made a change is gone by the time of ⇧⌘Z: typing
    // that had not submitted submits before its Undo, so the library has the step.
    @Test(.timeLimit(.minutes(1)))
    func redoWorksAfterTheOwnerOfItsStepIsGone() async throws {
        // A field that goes after ⌘Z of typing that never saved.
        let calibers = try await FieldLibrary.make()
        let undo = UndoManager()
        undo.groupsByEvent = false
        do {
            let maker = calibers.field(
                "Maker", text: "", fact: CaliberFact.maker, shown: { $0.manufacturer ?? "" })
            maker.beginEditing()
            grouped(undo) { maker.change(to: "Omega", undoManager: undo) }
            undo.undo()
            #expect(maker.text.isEmpty)
            await calibers.queue.waitUntilIdle()
        }
        undo.redo()
        await calibers.queue.waitUntilIdle()
        #expect(try await calibers.stored().manufacturer == "Omega")
        undo.undo()
        await calibers.queue.waitUntilIdle()
        #expect(try await calibers.stored().manufacturer == nil)
        try await calibers.close()

        // A part's name typed just before ⌘Z of the typing and of the part's addition, which
        // takes the part's fields away.
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let editing = EditingFixture.make(coordinator, pause: PauseGate().pause)
        let parts = editing.parts
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { !parts.isLoading }
        var adding: EditTicket?
        grouped(undo) { adding = parts.add(named: "Mainspring", to: job.id, undoManager: undo) }
        let part = try #require(await adding?.part)
        do {
            let name = try #require(parts.facts(for: part.id)?.name)
            name.beginEditing()
            grouped(undo) { name.change(to: "Mainspring 1.10", undoManager: undo) }
        }
        undo.undo()
        undo.undo()
        await editing.queue.waitUntilIdle()
        #expect(try await partName(part.id, coordinator) == nil)
        undo.redo()
        undo.redo()
        await editing.queue.waitUntilIdle()
        #expect(try await partName(part.id, coordinator) == "Mainspring 1.10")
        #expect(editing.queue.failure == nil)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    // Rule 2: Undo comes from the stored data. Each edit reads its inverse in its own
    // transaction, and it is right, because the library holds every edit before it. A field or
    // the checklist shows its Undo at once, and that change saves like any edit. So Redo works
    // also when the field is gone by then, and after a failed save.
    @Test(.timeLimit(.minutes(1)))
    func undoComesFromTheStoredDataAlsoAfterAFailedSave() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let editing = EditingFixture.make(coordinator, pause: PauseGate().pause)
        let parts = editing.parts
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { !parts.isLoading }
        let undo = UndoManager()
        undo.groupsByEvent = false

        // A part named A, renamed to B and then C. The Undo of C fails and waits, and Try Again
        // saves it, so the library holds B again before the next ⌘Z.
        var adding: EditTicket?
        grouped(undo) { adding = parts.add(named: "A", to: job.id, undoManager: undo) }
        let part = try #require(await adding?.part)
        do {
            let name = try #require(parts.facts(for: part.id)?.name)
            name.beginEditing()
            for text in ["B", "C"] {
                grouped(undo) { name.change(to: text, undoManager: undo) }
                name.saveNow()
            }
            await editing.queue.waitUntilIdle()
            try await JobTaskFixture.failWrites(coordinator, on: "part")
            undo.undo()
            #expect(name.text == "B")
            #expect(await editing.queue.waitUntilStopped())
            try await JobTaskFixture.allowWrites(coordinator, on: "part")
            editing.queue.retry()
            #expect(await !editing.queue.waitUntilStopped())
            #expect(try await partName(part.id, coordinator) == "B")
            undo.undo()
            await editing.queue.waitUntilIdle()
            #expect(try await partName(part.id, coordinator) == "A")
        }

        // ⌘Z of the addition takes the part's fields away. Redo brings back the part and then
        // the rename to B, from the stored data.
        undo.undo()
        await editing.queue.waitUntilIdle()
        #expect(try await partName(part.id, coordinator) == nil)
        undo.redo()
        undo.redo()
        await editing.queue.waitUntilIdle()
        #expect(try await partName(part.id, coordinator) == "B")
        #expect(editing.queue.failure == nil)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    private func permutations(of steps: [ChecklistStep]) -> [[ChecklistStep]] {
        guard steps.count > 1 else { return [steps] }
        var all: [[ChecklistStep]] = []
        for (index, step) in steps.enumerated() {
            var rest = steps
            rest.remove(at: index)
            for order in permutations(of: rest) { all.append([step] + order) }
        }
        return all
    }

    private func partName(_ id: UUID, _ coordinator: LibraryCoordinator) async throws -> String? {
        try await coordinator.read { try PartQueries.fetch(id, in: $0) }?.name
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw EditRuleTimeout()
    }

    // The test host turns off undo grouping by event, so each action opens its own group, as a
    // key press does in the app.
    private func grouped(_ undo: UndoManager, _ action: () -> Void) {
        undo.beginUndoGrouping()
        action()
        undo.endUndoGrouping()
    }
}

nonisolated private struct EditRuleTimeout: Error {}
