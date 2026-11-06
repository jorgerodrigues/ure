import AppKit
import Foundation
import GRDB
import Testing

@testable import Ure

// The one ordered queue that every change to the library goes through.
struct EditQueueTests {
    @Test(.timeLimit(.minutes(1)))
    func editsOfEveryKindRunInTheOrderTheyWereSubmitted() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let caliber = try await CaliberService(coordinator: coordinator).create(named: "552")
        let queue = EditQueue(coordinator: coordinator)

        // The library is held, so every edit waits. Each edit only works after the one before:
        // a job takes what it waits for only while it is Waiting, and Done clears it again.
        let (hold, holding) = try await LibraryHold.start(on: coordinator)
        defer { hold.release() }
        let step = ChecklistStep(id: UUID(), text: "Fit the crystal")
        let edits: [(LibraryEdit, EditScope)] = [
            (.job(.stage(job.id, .waiting)), .jobs),
            (.job(.set(job.id, .waitingFor("a crystal"))), .jobs),
            (.part(.add(name: "Crystal", description: "", job: job.id)), .parts),
            (.caliber(.set(caliber.id, .maker("Omega"))), .calibers),
            (.notes(.job(job.id), "Ordered from Cousins"), .notes(.job(job.id))),
            (.job(.stage(job.id, .done)), .jobs),
            (.checklist(job.id, [.place(step, after: nil)]), .checklist(job.id)),
        ]
        var finished: [Int] = []
        var tickets: [EditTicket] = []
        for (index, (edit, scope)) in edits.enumerated() {
            tickets.append(queue.submit(edit, in: scope) { _ in finished.append(index) })
        }
        #expect(!queue.isIdle && queue.isBusy && queue.isBusy(.jobs) && finished.isEmpty)
        hold.release()
        _ = try await holding.value
        await queue.waitUntilIdle()

        #expect(finished == Array(edits.indices) && queue.isIdle && !queue.isBusy)
        for ticket in tickets { #expect(await ticket.saved) }
        #expect(queue.failures.isEmpty)
        let saved = try #require(
            try await coordinator.read { try JobQueries.fetch(job.id, in: $0) })
        #expect(saved.stage == .done && saved.waitingFor == nil)
        #expect(
            try await coordinator.read { try PartQueries.fetchAll($0) }.map(\.name) == ["Crystal"])
        #expect(
            try await coordinator.read { try CaliberQueries.fetch(caliber.id, in: $0) }?
                .manufacturer == "Omega")
        #expect(
            try await RecordNotesService(coordinator: coordinator).text(for: .job(job.id))
                == "Ordered from Cousins")
        #expect(
            try await coordinator.read { try ChecklistQueries.ordered(for: job.id, in: $0) }
                .map(\.text) == ["Fit the crystal"])
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func undoAndRedoKeepTheOrderYouActedInWhileSavesWait() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let queue = EditQueue(coordinator: coordinator)
        let undo = UndoManager()
        undo.groupsByEvent = false

        // A part is added, then renamed. Undo must take back the rename before the part goes,
        // because a rename of a part that is gone fails.
        undo.beginUndoGrouping()
        let adding = queue.submit(
            .part(.add(name: "Mainspring", description: "", job: job.id)), in: .parts,
            undo: "Add Part", undoManager: undo)
        undo.endUndoGrouping()
        let part = try #require(await adding.part)
        undo.beginUndoGrouping()
        queue.submit(
            .part(.set(part.id, .name("Mainspring 1.10"))), in: .parts, undo: "Part Name",
            undoManager: undo)
        undo.endUndoGrouping()
        await queue.waitUntilIdle()

        // Both Undo steps are taken while the library is held, before either can save.
        var (hold, holding) = try await LibraryHold.start(on: coordinator)
        undo.undo()
        undo.undo()
        #expect(undo.redoActionName == "Add Part" && !undo.canUndo && !queue.isIdle)
        hold.release()
        _ = try await holding.value
        await queue.waitUntilIdle()
        #expect(try await stored(part.id, coordinator) == nil && queue.failures.isEmpty)

        // Redo gives back the part and then its new name, also while the library is held.
        (hold, holding) = try await LibraryHold.start(on: coordinator)
        undo.redo()
        undo.redo()
        #expect(undo.undoActionName == "Part Name" && !undo.canRedo)
        hold.release()
        _ = try await holding.value
        await queue.waitUntilIdle()
        #expect(try await stored(part.id, coordinator)?.name == "Mainspring 1.10")
        #expect(queue.failures.isEmpty)

        // Forgetting the Undo steps, as before a restore, leaves nothing to undo.
        queue.discardUndo()
        #expect(!undo.canUndo && !undo.canRedo)
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailedEditIsReportedOnceAndTheEditsAfterItStillRun() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let watchID = try #require(job.watchID)
        let caliber = try await CaliberService(coordinator: coordinator).create(named: "552")
        let editing = EditingFixture.make(coordinator, pause: PauseGate().pause)
        let queue = editing.queue
        let observation = Task { await editing.watches.observe() }
        defer { observation.cancel() }
        try await waitUntil { !editing.watches.isLoading }

        try await JobTaskFixture.failWrites(coordinator, on: "watch")
        let failing = queue.submit(.watch(.archive(watchID, true)), in: .watches)
        // Typing that fails goes back to its field, which keeps the text with Try Again.
        let owner = try #require(editing.watches.facts(for: watchID)?.owner)
        owner.beginEditing()
        owner.change(to: "Ana Ribeiro", undoManager: nil)
        owner.endEditing()
        let naming = queue.submit(.caliber(.set(caliber.id, .maker("Omega"))), in: .calibers)
        let adding = queue.submit(
            .part(.add(name: "Crystal", description: "", job: job.id)), in: .parts)
        await queue.waitUntilIdle()

        #expect(await !failing.saved)
        #expect(await naming.saved)
        #expect(await adding.saved)
        #expect(editing.watches.saveError != nil && queue.failures.count == 1)
        #expect(owner.saveError != nil && owner.text == "Ana Ribeiro" && queue.hasUnsavedTyping)
        #expect(
            try await coordinator.read { try CaliberQueries.fetch(caliber.id, in: $0) }?
                .manufacturer == "Omega")

        // Try Again saves the text, and the next change where the failure shows clears it.
        try await JobTaskFixture.allowWrites(coordinator, on: "watch")
        owner.saveNow()
        #expect(await queue.submit(.watch(.archive(watchID, true)), in: .watches).saved)
        #expect(queue.failures.isEmpty && owner.saveError == nil && !queue.hasUnsavedTyping)
        #expect(
            try await coordinator.read { try WatchQueries.fetch(watchID, in: $0) }?.owner
                == "Ana Ribeiro")
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func savingEverythingWaitsAlsoForAChangeMadeWhileItWaits() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let editing = EditingFixture.make(coordinator, pause: PauseGate().pause)
        let observation = Task { await editing.jobs.observe() }
        defer { observation.cancel() }
        try await waitUntil { !editing.jobs.isLoading }
        let title = try #require(editing.jobs.facts(for: job.id)?.title)
        title.beginEditing()
        title.change(to: "Full service", undoManager: nil)

        // Quitting starts while the library is held, and the typing waits to save. A part is
        // added after that, while the first change still waits.
        let (hold, holding) = try await LibraryHold.start(on: coordinator)
        defer { hold.release() }
        var quit = false
        let quitting = Task {
            let saved = await editing.saveAllFields()
            quit = true
            return saved
        }
        try await waitUntil { !editing.queue.isIdle }
        let adding = editing.parts.add(named: "Crystal", to: job.id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!quit && editing.isSaving)
        hold.release()
        _ = try await holding.value
        #expect(await quitting.value)
        // Quitting went ahead only once both had saved.
        #expect(adding?.isPending == false && editing.queue.isIdle)
        #expect(
            try await coordinator.read { try JobQueries.fetch(job.id, in: $0) }?.title
                == "Full service")
        #expect(
            try await coordinator.read { try PartQueries.fetchAll($0) }.map(\.name) == ["Crystal"])
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aChecklistChangeMadeWhileAnUndoWaitsKeepsTheUndo() async throws {
        let first = ChecklistStep(id: UUID(), text: "Clean all parts")
        let second = ChecklistStep(id: UUID(), text: "Oil the escapement")
        let library = try await ChecklistLibrary.make(steps: [first, second])
        let editor = library.editor
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.toggleTick(first.id, undoManager: undo)
        undo.endUndoGrouping()
        await library.queue.waitUntilIdle()

        // ⌘Z takes back the first tick while the library is held, and the second step is
        // ticked before that Undo has run.
        let (hold, holding) = try await LibraryHold.start(on: library.coordinator)
        undo.undo()
        undo.beginUndoGrouping()
        editor.toggleTick(second.id, undoManager: undo)
        undo.endUndoGrouping()
        hold.release()
        _ = try await holding.value
        await library.queue.waitUntilIdle()
        let saved = try await library.stored()
        #expect(saved.map(\.isTicked) == [false, true])
        #expect(editor.steps.map(\.isTicked) == [false, true] && !editor.hasUnsavedChanges)
        try await library.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func anUndoThatFailedCanBeTriedAgain() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let editing = EditingFixture.make(coordinator)
        let parts = editing.parts
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { !parts.isLoading }
        let part = try #require(await parts.add(named: "Mainspring", to: job.id)?.part)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let removing = parts.remove(part.id, undoManager: undo)
        undo.endUndoGrouping()
        #expect(await removing.didSave)

        // The part can't come back while the library refuses writes.
        try await JobTaskFixture.failWrites(coordinator, on: "part")
        undo.undo()
        await editing.queue.waitUntilIdle()
        #expect(try await stored(part.id, coordinator) == nil && parts.saveError != nil)
        try await JobTaskFixture.allowWrites(coordinator, on: "part")
        // The deletion still holds, so Redo does nothing, and the next Undo brings the part back.
        undo.redo()
        await editing.queue.waitUntilIdle()
        #expect(try await stored(part.id, coordinator) == nil)
        undo.undo()
        await editing.queue.waitUntilIdle()
        #expect(try await stored(part.id, coordinator)?.name == "Mainspring")
        #expect(parts.saveError == nil)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func undoTakesBackAChecklistChangeThatDidNotSave() async throws {
        let step = ChecklistStep(id: UUID(), text: "Clean all parts")
        let library = try await ChecklistLibrary.make(steps: [step])
        let editor = library.editor
        let undo = UndoManager()
        undo.groupsByEvent = false
        try await JobTaskFixture.failWrites(library.coordinator, on: "checklistStep")
        undo.beginUndoGrouping()
        editor.toggleTick(step.id, undoManager: undo)
        undo.endUndoGrouping()
        await library.queue.waitUntilIdle()
        #expect(editor.saveError != nil && editor.step(step.id)?.isTicked == true)
        undo.undo()
        await library.queue.waitUntilIdle()
        #expect(editor.saveError == nil && editor.step(step.id)?.isTicked == false)
        #expect(!library.queue.hasUnsavedTyping)
        try await JobTaskFixture.allowWrites(library.coordinator, on: "checklistStep")
        #expect(await library.queue.saveEverything())
        #expect(try await library.stored() == [step])
        try await library.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func escIsAnUndoStepOfItsOwn() async throws {
        let library = try await NotesLibrary.make(notes: "Saved", pause: PauseGate().pause)
        let field = library.field
        let undo = UndoManager()
        undo.groupsByEvent = false
        field.beginEditing()
        undo.beginUndoGrouping()
        field.change(to: "Saved and typed", undoManager: undo)
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        field.revert(undoManager: undo)
        undo.endUndoGrouping()
        #expect(field.text == "Saved")
        await library.queue.waitUntilIdle()
        #expect(try await library.stored() == "Saved")
        // ⌘Z brings back the typing that Esc took away, and ⌘Z again takes it back too.
        undo.undo()
        await library.queue.waitUntilIdle()
        #expect(field.text == "Saved and typed")
        #expect(try await library.stored() == "Saved and typed")
        undo.undo()
        await library.queue.waitUntilIdle()
        #expect(field.text == "Saved")
        #expect(try await library.stored() == "Saved")
        try await library.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func typingAfterAFailedSaveThatALaterSaveTookOverIsItsOwnUndoStep() async throws {
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
        let part = try #require(await parts.add(named: "Mainspring", to: job.id)?.part)
        let name = try #require(parts.facts(for: part.id)?.name)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: """
                    CREATE TRIGGER failBadName BEFORE UPDATE ON part WHEN NEW.name = 'Bad'
                    BEGIN SELECT RAISE(ABORT, 'fixture disk failure'); END
                    """)
        }
        let undo = UndoManager()
        undo.groupsByEvent = false
        name.beginEditing()

        // Two bursts save while the library is held. The first fails and the second saves.
        let (hold, holding) = try await LibraryHold.start(on: coordinator)
        for text in ["Bad", "Good"] {
            undo.beginUndoGrouping()
            name.change(to: text, undoManager: undo)
            undo.endUndoGrouping()
            name.saveNow()
        }
        hold.release()
        _ = try await holding.value
        await editing.queue.waitUntilIdle()
        #expect(try await stored(part.id, coordinator)?.name == "Good" && name.saveError == nil)

        // The next burst is an Undo step of its own, so ⌘Z takes back only that one.
        undo.beginUndoGrouping()
        name.change(to: "Good again", undoManager: undo)
        undo.endUndoGrouping()
        name.saveNow()
        await editing.queue.waitUntilIdle()
        undo.undo()
        await editing.queue.waitUntilIdle()
        #expect(try await stored(part.id, coordinator)?.name == "Good")
        undo.undo()
        await editing.queue.waitUntilIdle()
        #expect(try await stored(part.id, coordinator)?.name == "Mainspring")
        name.endEditing()
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aTitleThatDidNotSaveGoesWithItsMaterial() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        let link = try await MaterialService(coordinator: coordinator).addLink(
            try #require(URL(string: "https://example.org")), for: owner)
        let editing = EditingFixture.make(coordinator, pause: PauseGate().pause)
        let material = editing.material
        let observation = Task { await material.observe() }
        defer { observation.cancel() }
        try await waitUntil { material.records.count == 1 }
        let title = try #require(material.titleField(for: link.id))
        try await JobTaskFixture.failWrites(coordinator, on: "libraryItem")
        title.beginEditing()
        title.change(to: "Supplier page", undoManager: nil)
        title.endEditing()
        await editing.queue.waitUntilIdle()
        #expect(title.saveError != nil && editing.hasUnsavedFields)
        try await JobTaskFixture.allowWrites(coordinator, on: "libraryItem")
        let record = try #require(material.records.first)
        let removing = material.remove(record, on: owner, undoManager: nil)
        #expect(await removing.didSave)
        #expect(!editing.hasUnsavedFields && material.titleField(for: link.id) == nil)
        #expect(await editing.saveAllFields())
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    private func stored(_ id: UUID, _ coordinator: LibraryCoordinator) async throws
        -> PartRecord?
    {
        try await coordinator.read { try PartQueries.fetch(id, in: $0) }
    }
}

// One test for each kind of save-order and Undo bug that reviews found in the Rework stories,
// written against the queue.
struct EditQueueRegressionTests {
    // Typing on one record never lands on another, also when you switch records before it has
    // saved, and ⌘Z takes back each record's typing on that record.
    @Test(.timeLimit(.minutes(1)))
    func typingStaysWithTheRecordItWasTypedOnAfterSwitching() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let service = CaliberService(coordinator: coordinator)
        let first = try await service.create(named: "552")
        let second = try await service.create(named: "2824-2")
        let editing = EditingFixture.make(coordinator, pause: PauseGate().pause)
        let calibers = editing.calibers
        let observation = Task { await calibers.observe() }
        defer { observation.cancel() }
        try await waitUntil { calibers.calibers.count == 2 }
        let undo = UndoManager()
        undo.groupsByEvent = false

        calibers.select(first.id)
        let firstMaker = try #require(calibers.facts(for: first.id)?.maker)
        firstMaker.beginEditing()
        undo.beginUndoGrouping()
        firstMaker.change(to: "Omega", undoManager: undo)
        undo.endUndoGrouping()
        editing.requestNavigation { calibers.select(second.id) }
        firstMaker.endEditing()
        let secondMaker = try #require(calibers.facts(for: second.id)?.maker)
        secondMaker.beginEditing()
        undo.beginUndoGrouping()
        secondMaker.change(to: "ETA", undoManager: undo)
        undo.endUndoGrouping()
        secondMaker.endEditing()
        await editing.queue.waitUntilIdle()
        #expect(try await maker(of: first.id, coordinator) == "Omega")
        #expect(try await maker(of: second.id, coordinator) == "ETA")

        undo.undo()
        await editing.queue.waitUntilIdle()
        #expect(try await maker(of: second.id, coordinator) == nil)
        #expect(try await maker(of: first.id, coordinator) == "Omega")
        undo.undo()
        await editing.queue.waitUntilIdle()
        #expect(try await maker(of: first.id, coordinator) == nil)
        #expect(firstMaker.text.isEmpty && secondMaker.text.isEmpty)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    // Two quick ⌘Z presses, while the library is held, take back a job's state and then the
    // waiting text typed before it, in that order, and Redo gives both back in order.
    @Test(.timeLimit(.minutes(1)))
    func twoQuickUndosOfAStateAndItsWaitingTextRunInOrder() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let editing = EditingFixture.make(coordinator, pause: PauseGate().pause)
        let jobs = editing.jobs
        let observation = Task { await jobs.observe() }
        defer { observation.cancel() }
        try await waitUntil { jobs.jobs.count == 1 }
        jobs.open(try #require(jobs.jobs.first))
        let undo = UndoManager()
        undo.groupsByEvent = false

        undo.beginUndoGrouping()
        let waiting = jobs.setStage(.waiting, undoManager: undo)
        undo.endUndoGrouping()
        #expect(await waiting.didSave)
        let field = try #require(jobs.facts(for: job.id)?.waitingFor)
        field.beginEditing()
        undo.beginUndoGrouping()
        field.change(to: "a crystal", undoManager: undo)
        undo.endUndoGrouping()
        // Done comes while the waiting text is still being typed, so the text saves first.
        undo.beginUndoGrouping()
        let done = jobs.setStage(.done, undoManager: undo)
        undo.endUndoGrouping()
        #expect(await done.didSave)

        let (hold, holding) = try await LibraryHold.start(on: coordinator)
        undo.undo()
        undo.undo()
        hold.release()
        _ = try await holding.value
        await editing.queue.waitUntilIdle()
        var saved = try #require(try await stored(job.id, coordinator))
        #expect(saved.stage == .waiting && saved.waitingFor == nil)
        #expect(field.text.isEmpty && field.saveError == nil && jobs.saveError == nil)

        undo.redo()
        await editing.queue.waitUntilIdle()
        #expect(try await stored(job.id, coordinator)?.waitingFor == "a crystal")
        undo.redo()
        await editing.queue.waitUntilIdle()
        saved = try #require(try await stored(job.id, coordinator))
        #expect(saved.stage == .done && saved.waitingFor == nil && jobs.saveError == nil)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    // Parts typed on a job's add line and a spare used after them keep the order you added
    // them in, also while every save waits.
    @Test(.timeLimit(.minutes(1)))
    func aSpareUsedAfterTypedPartsKeepsItsPlace() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let spare = try await PartService(coordinator: coordinator).add(
            named: "Crystal 30.0 mm", to: nil)
        let editing = EditingFixture.make(coordinator)
        let parts = editing.parts
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { parts.parts.count == 1 }
        let entry = parts.entry(for: job.id)
        entry.beginEditing()

        let (hold, holding) = try await LibraryHold.start(on: coordinator)
        defer { hold.release() }
        for name in ["Mainspring", "Hairspring"] {
            entry.change(to: name)
            parts.submitCommand(entry, undoManager: nil)
        }
        entry.change(to: "crystal")
        entry.moveHighlight(down: true)
        #expect(entry.highlightedID == spare.id)
        parts.submitCommand(entry, undoManager: nil)
        hold.release()
        _ = try await holding.value
        await editing.queue.waitUntilIdle()
        let order = ["Mainspring", "Hairspring", "Crystal 30.0 mm"]
        #expect(parts.parts(on: job.id).map(\.name) == order)
        let saved = try await coordinator.read { try PartQueries.fetchAll($0) }
        #expect(
            saved.filter { $0.jobID == job.id }.sorted { $0.position < $1.position }.map(\.name)
                == order)
        entry.endEditing()
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    // Quitting waits for every change still saving, also when two Undo steps of archives are
    // queued and the first has saved while the second still waits.
    @Test(.timeLimit(.minutes(1)))
    func quittingWaitsForASecondChangeStillSaving() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let service = WatchService(coordinator: coordinator)
        let first = try await service.create(named: "Seamaster")
        let second = try await service.create(named: "Ventura")
        let editing = EditingFixture.make(coordinator)
        let watches = editing.watches
        let observation = Task { await watches.observe() }
        defer { observation.cancel() }
        try await waitUntil { watches.watches.count == 2 }
        let undo = UndoManager()
        undo.groupsByEvent = false
        for watch in [first, second] {
            watches.select(watch.id)
            undo.beginUndoGrouping()
            let archiving = watches.toggleArchive(undoManager: undo)
            undo.endUndoGrouping()
            #expect(await archiving.didSave)
        }

        let (hold, holding) = try await LibraryHold.start(on: coordinator)
        defer { hold.release() }
        undo.undo()
        undo.undo()
        let quitting = Task { await editing.saveAllFields() }
        #expect(editing.isSaving && !editing.queue.isIdle)
        hold.release()
        _ = try await holding.value
        #expect(await quitting.value)
        let stored = try await coordinator.read(WatchQueries.fetchAll)
        #expect(stored.allSatisfy { $0.archivedAt == nil } && !editing.isSaving)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    // ⌘Z after an undone part deletion reaches the rename made before it. The part's fields
    // went with it, and no field is needed, because Undo comes from the stored part.
    @Test(.timeLimit(.minutes(1)))
    func undoAfterAnUndoneDeletionReachesTheTypingBeforeIt() async throws {
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

        undo.beginUndoGrouping()
        let adding = parts.add(named: "Mainspring", to: job.id, undoManager: undo)
        undo.endUndoGrouping()
        let part = try #require(await adding?.part)
        do {
            let name = try #require(parts.facts(for: part.id)?.name)
            name.beginEditing()
            undo.beginUndoGrouping()
            name.change(to: "Mainspring 1.10", undoManager: undo)
            undo.endUndoGrouping()
        }
        undo.beginUndoGrouping()
        let removing = parts.remove(part.id, undoManager: undo)
        undo.endUndoGrouping()
        #expect(await removing.didSave)
        #expect(parts.facts(for: part.id) == nil)

        for expected in ["Mainspring 1.10", "Mainspring"] {
            undo.undo()
            await editing.queue.waitUntilIdle()
            #expect(try await PartStateReading.name(of: part.id, coordinator) == expected)
            #expect(parts.facts(for: part.id)?.name.text == expected)
        }
        undo.undo()
        await editing.queue.waitUntilIdle()
        #expect(try await PartStateReading.name(of: part.id, coordinator) == nil)
        for expected in ["Mainspring", "Mainspring 1.10"] {
            undo.redo()
            await editing.queue.waitUntilIdle()
            #expect(try await PartStateReading.name(of: part.id, coordinator) == expected)
        }
        undo.redo()
        await editing.queue.waitUntilIdle()
        #expect(parts.part(part.id) == nil && editing.queue.failures.isEmpty)
        #expect(!editing.hasUnsavedFields)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    // A change reads what you typed before it, because the typing saves first. Notes and a
    // material title typed just before an archive save before the watch is archived, so they
    // are not left unsaved on a page that can't change any more. A job being set up keeps the
    // title typed just before a pick that would discard it while blank.
    @Test(.timeLimit(.minutes(1)))
    func aChangeSeesWhatWasTypedJustBeforeIt() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await WatchService(coordinator: coordinator).create(named: "Seamaster")
        let link = try await MaterialService(coordinator: coordinator).addLink(
            try #require(URL(string: "https://example.org")), for: .watch(watch.id))
        let editing = EditingFixture.make(coordinator, pause: PauseGate().pause)
        let observations = [
            Task { await editing.watches.observe() }, Task { await editing.material.observe() },
            Task { await editing.jobs.observe() },
        ]
        defer { observations.forEach { $0.cancel() } }
        try await waitUntil {
            editing.watches.watches.count == 1 && editing.material.records.count == 1
                && !editing.jobs.isLoading
        }
        await editing.notes.load(.watch(watch.id))
        let notes = try #require(editing.notes.field(for: .watch(watch.id)))
        notes.beginEditing()
        notes.change(to: "Crown tube replaced", undoManager: nil)
        let title = try #require(editing.material.titleField(for: link.id))
        title.beginEditing()
        title.change(to: "Supplier page", undoManager: nil)
        editing.watches.select(watch.id)
        #expect(await editing.watches.toggleArchive().didSave)
        #expect(notes.saveError == nil && title.saveError == nil && !editing.hasUnsavedFields)
        #expect(
            try await RecordNotesService(coordinator: coordinator).text(for: .watch(watch.id))
                == "Crown tube replaced")
        #expect(
            try await coordinator.read(LibraryItemQueries.fetchAll).first?.title
                == "Supplier page")

        let ventura = try await WatchService(coordinator: coordinator).create(named: "Ventura")
        _ = try await JobService(coordinator: coordinator).start(for: ventura.id)
        try await waitUntil { editing.jobs.jobs.count == 1 && editing.watches.watches.count == 2 }
        #expect(await editing.jobs.create().didSave)
        let blank = try #require(editing.jobs.selectedID)
        let jobTitle = try #require(editing.jobs.facts(for: blank)?.title)
        jobTitle.beginEditing()
        jobTitle.change(to: "Strap and buckle", undoManager: nil)
        let picker = WatchPickerModel()
        picker.type("vent")
        let items = picker.items(
            watches: editing.watches.watches, calibers: [], jobs: editing.jobs.jobs)
        let item = try #require(items.first)
        #expect(picker.pick(item, editing: editing, undoManager: nil))
        await editing.queue.waitUntilIdle()
        #expect(
            try await coordinator.read { try JobQueries.fetch(blank, in: $0) }?.title
                == "Strap and buckle")
        observations.forEach { $0.cancel() }
        for observation in observations { await observation.value }
        try await coordinator.close()
    }

    private func maker(of id: UUID, _ coordinator: LibraryCoordinator) async throws -> String? {
        try await coordinator.read { try CaliberQueries.fetch(id, in: $0) }?.manufacturer
    }

    private func stored(_ id: UUID, _ coordinator: LibraryCoordinator) async throws -> JobRecord? {
        try await coordinator.read { try JobQueries.fetch(id, in: $0) }
    }
}

nonisolated private enum PartStateReading {
    static func name(of id: UUID, _ coordinator: LibraryCoordinator) async throws -> String? {
        try await coordinator.read { try PartQueries.fetch(id, in: $0) }?.name
    }
}

private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw EditQueueTimeout()
}

nonisolated private struct EditQueueTimeout: Error {}
