import AppKit
import Foundation
import GRDB
import Synchronization
import Testing

@testable import Ure

struct PartStateTests {
    @Test(.timeLimit(.minutes(1)))
    func clickingTheStateMovesItOnAndUndoPutsBackTheStateWithItsDay() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = PartClock()
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: clock.now))
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let parts = PartState(
            service: PartService(coordinator: coordinator),
            queue: EditQueue(coordinator: coordinator))
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { !parts.isLoading }
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        let part = try #require(await parts.add(named: "Mainspring", to: job.id)?.part)
        clock.set(1_000)
        undoManager.beginUndoGrouping()
        let click = parts.advance(part.id, undoManager: undoManager)
        undoManager.endUndoGrouping()
        #expect(await click.didSave)
        #expect(parts.part(part.id)?.stage == .ordered)
        #expect(parts.part(part.id)?.orderedAt == clock.date(1_000))
        #expect(undoManager.undoActionName == PartState.stageActionName)

        clock.set(2_000)
        undoManager.undo()
        await parts.queue.waitUntilIdle()
        var saved = try await stored(part.id, coordinator)
        #expect(saved.stage == .needed && saved.orderedAt == nil)
        #expect(parts.part(part.id)?.stage == .needed)
        // Redo gives back the state with the day it was given, not the day of the Redo.
        undoManager.redo()
        await parts.queue.waitUntilIdle()
        saved = try await stored(part.id, coordinator)
        #expect(saved.stage == .ordered && saved.orderedAt == clock.date(1_000))

        // Two quick choices from the pop-up end at the last one, even when it is the state the
        // part had before the first saved.
        #expect(await parts.setStage(.needed, of: part.id).didSave)
        parts.setStage(.ordered, of: part.id)
        parts.setStage(.needed, of: part.id)
        await parts.queue.waitUntilIdle()
        #expect(try await stored(part.id, coordinator).stage == .needed)
        #expect(await parts.setStage(.ordered, of: part.id).didSave)

        // Two quick clicks move the part on twice.
        parts.advance(part.id, undoManager: nil)
        parts.advance(part.id, undoManager: nil)
        await parts.queue.waitUntilIdle()
        #expect(try await stored(part.id, coordinator).stage == .fitted)
        #expect(await parts.setStage(.ordered, of: part.id).didSave)

        // Each click is its own Undo step, and a fitted part stays fitted.
        for _ in 0..<2 {
            undoManager.beginUndoGrouping()
            let click = parts.advance(part.id, undoManager: undoManager)
            undoManager.endUndoGrouping()
            #expect(await click.didSave)
        }
        #expect(parts.part(part.id)?.stage == .fitted)
        #expect(parts.advance(part.id, undoManager: undoManager) == nil)
        undoManager.undo()
        await parts.queue.waitUntilIdle()
        #expect(try await stored(part.id, coordinator).stage == .inHand)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func addingAndDeletingAPartUndo() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let parts = PartState(
            service: PartService(coordinator: coordinator),
            queue: EditQueue(coordinator: coordinator))
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { !parts.isLoading }
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        #expect(parts.add(named: "  ", to: job.id) == nil)
        undoManager.beginUndoGrouping()
        let adding = parts.add(named: "Mainspring", to: job.id, undoManager: undoManager)
        undoManager.endUndoGrouping()
        let mainspring = try #require(await adding?.part)
        let crystal = try #require(await parts.add(named: "Crystal", to: job.id)?.part)
        #expect(parts.parts(on: job.id).map(\.name) == ["Mainspring", "Crystal"])
        #expect(undoManager.undoActionName == PartState.addActionName)
        undoManager.undo()
        await parts.queue.waitUntilIdle()
        #expect(parts.parts(on: job.id).map(\.id) == [crystal.id])
        undoManager.redo()
        await parts.queue.waitUntilIdle()
        try await waitUntil { parts.parts(on: job.id).count == 2 }
        #expect(parts.parts(on: job.id).map(\.id) == [mainspring.id, crystal.id])

        try await coordinator.mutate { db, _, _ in
            try PartLink(
                id: UUID(), partID: crystal.id, position: 0, url: "https://example.org/crystal",
                createdAt: .now, updatedAt: .now
            ).insert(db)
        }
        try await waitUntil { parts.links(of: crystal.id).count == 1 }
        parts.select(crystal.id)
        undoManager.beginUndoGrouping()
        let removing = parts.remove(crystal.id, undoManager: undoManager)
        undoManager.endUndoGrouping()
        #expect(await removing.didSave)
        #expect(parts.selectedID == nil && parts.part(crystal.id) == nil)
        #expect(undoManager.undoActionName == PartState.removeActionName)
        #expect(try await coordinator.read { try PartQueries.fetch(crystal.id, in: $0) } == nil)
        undoManager.undo()
        await parts.queue.waitUntilIdle()
        try await waitUntil {
            parts.part(crystal.id) != nil && parts.links(of: crystal.id).count == 1
        }
        #expect(try await stored(crystal.id, coordinator) == crystal)

        // A part deleted with a quantity it can't save leaves nothing unsaved behind, so quit
        // and restore ask nothing. Undo brings it back with its saved quantity.
        let facts = try #require(parts.facts(for: crystal.id))
        facts.quantity.beginEditing()
        facts.quantity.change(to: "0", undoManager: nil)
        facts.quantity.endEditing()
        #expect(parts.queue.hasUnsavedTyping)
        undoManager.beginUndoGrouping()
        let removingAgain = parts.remove(crystal.id, undoManager: undoManager)
        undoManager.endUndoGrouping()
        #expect(await removingAgain.didSave)
        #expect(!parts.queue.hasUnsavedTyping && parts.facts(for: crystal.id) == nil)
        undoManager.undo()
        await parts.queue.waitUntilIdle()
        try await waitUntil { parts.facts(for: crystal.id) != nil }
        #expect(parts.facts(for: crystal.id)?.quantity.text == "1" && !parts.queue.hasUnsavedTyping)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func undoReachesTypingOnAPartAfterItComesBack() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let parts = PartState(
            service: PartService(coordinator: coordinator),
            queue: EditQueue(coordinator: coordinator))
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { !parts.isLoading }
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        // The test keeps no field of its own, so only the parts keep them alive, as on screen
        // once the part's line has gone.
        undoManager.beginUndoGrouping()
        let adding = parts.add(named: "Mainspring", to: job.id, undoManager: undoManager)
        undoManager.endUndoGrouping()
        let part = try #require(await adding?.part)
        try rename(part.id, to: "Mainspring 1.10", in: parts, undoManager)
        try await waitUntilStored(part.id, named: "Mainspring 1.10", coordinator)
        undoManager.beginUndoGrouping()
        let removing = parts.remove(part.id, undoManager: undoManager)
        undoManager.endUndoGrouping()
        #expect(await removing.didSave)

        // ⌘Z brings the part back, then undoes the rename made before it was deleted, then the
        // addition.
        undoManager.undo()
        await parts.queue.waitUntilIdle()
        try await waitUntil { parts.facts(for: part.id) != nil }
        #expect(undoManager.undoActionName == "Part Name")
        undoManager.undo()
        await parts.queue.waitUntilIdle()
        #expect(parts.facts(for: part.id)?.name.text == "Mainspring")
        try await waitUntilStored(part.id, named: "Mainspring", coordinator)
        undoManager.undo()
        await parts.queue.waitUntilIdle()
        #expect(parts.part(part.id) == nil)

        // Shift-⌘Z adds the part again, then renames it again, then deletes it again.
        undoManager.redo()
        await parts.queue.waitUntilIdle()
        try await waitUntil { parts.facts(for: part.id) != nil }
        undoManager.redo()
        await parts.queue.waitUntilIdle()
        #expect(parts.facts(for: part.id)?.name.text == "Mainspring 1.10")
        try await waitUntilStored(part.id, named: "Mainspring 1.10", coordinator)
        undoManager.redo()
        await parts.queue.waitUntilIdle()
        #expect(parts.part(part.id) == nil && !parts.queue.hasUnsavedTyping)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    private func rename(
        _ id: UUID, to name: String, in parts: PartState, _ undoManager: UndoManager
    ) throws {
        let field = try #require(parts.facts(for: id)?.name)
        field.beginEditing()
        undoManager.beginUndoGrouping()
        field.change(to: name, undoManager: undoManager)
        undoManager.endUndoGrouping()
        field.endEditing()
    }

    private func waitUntilStored(
        _ id: UUID, named name: String, _ coordinator: LibraryCoordinator
    ) async throws {
        for _ in 0..<500 {
            if try await coordinator.read({ try PartQueries.fetch(id, in: $0) })?.name == name {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PartTimeout()
    }

    @Test(.timeLimit(.minutes(1)))
    func aNameThatDidNotSaveStaysWithTryAgainWhileTheNextIsTyped() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let parts = PartState(
            service: PartService(coordinator: coordinator),
            queue: EditQueue(coordinator: coordinator))
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { !parts.isLoading }
        let entry = parts.entry(for: job.id)
        entry.beginEditing()

        // Return empties the line at once, so the next name can follow while this one saves.
        entry.change(to: "Mainspring")
        entry.changeDescription(to: " ")
        parts.submitCommand(entry, undoManager: nil)
        #expect(entry.text.isEmpty && entry.description.isEmpty)
        try await waitUntil { parts.parts(on: job.id).map(\.name) == ["Mainspring"] }

        try await JobTaskFixture.failWrites(coordinator, on: "part")
        entry.change(to: "Crys")
        let crystal = PartEntryText(name: "Crystal", description: "Sapphire 30.0 mm")
        #expect(await !parts.submit(crystal, spare: nil, on: entry).didSave)
        #expect(entry.unsaved == [crystal] && entry.text == "Crys" && parts.queue.hasUnsavedTyping)
        #expect(await !parts.submit(PartEntryText(name: "Gasket"), spare: nil, on: entry).didSave)
        for ticket in parts.retryUnsaved(entry) { #expect(await !ticket.saved) }
        #expect(entry.unsaved.map(\.name) == ["Crystal", "Gasket"])
        // Quitting tries them again and says that they did not save.
        #expect(await !parts.queue.saveEverything())
        #expect(entry.unsaved.map(\.name) == ["Crystal", "Gasket"])
        try await JobTaskFixture.allowWrites(coordinator, on: "part")
        // Two Try Agains at once add each name once.
        parts.retryUnsaved(entry)
        parts.retryUnsaved(entry)
        await parts.queue.waitUntilIdle()
        #expect(entry.unsaved.isEmpty && !parts.queue.hasUnsavedTyping)
        #expect(await parts.queue.saveEverything())
        #expect(parts.parts(on: job.id).map(\.name) == ["Mainspring", "Crystal", "Gasket"])
        #expect(parts.parts(on: job.id).map(\.description) == [nil, "Sapphire 30.0 mm", nil])
        entry.endEditing()
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func typingOnTheAddLineUndoesBeforeThePartAddedBeforeIt() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let parts = PartState(
            service: PartService(coordinator: coordinator),
            queue: EditQueue(coordinator: coordinator))
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { !parts.isLoading }
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let entry = parts.entry(for: job.id)
        entry.beginEditing()

        undoManager.beginUndoGrouping()
        entry.change(to: "M", undoManager: undoManager)
        entry.change(to: "Mainspring", undoManager: undoManager)
        undoManager.endUndoGrouping()
        #expect(undoManager.undoActionName == PartEntryWording.typingActionName)
        undoManager.beginUndoGrouping()
        let typed = PartEntryText(name: entry.text)
        entry.clear()
        let adding = parts.submit(typed, spare: nil, on: entry, undoManager: undoManager)
        undoManager.endUndoGrouping()
        #expect(await adding.didSave)
        #expect(undoManager.undoActionName == PartState.addActionName)

        // ⌘Z undoes the typing of the next part first, and only then the part added before it.
        undoManager.beginUndoGrouping()
        entry.change(to: "Cry", undoManager: undoManager)
        entry.changeDescription(to: "30.0 mm", undoManager: undoManager)
        undoManager.endUndoGrouping()
        undoManager.undo()
        #expect(entry.text.isEmpty && entry.description.isEmpty)
        #expect(parts.parts(on: job.id).map(\.name) == ["Mainspring"])
        undoManager.redo()
        #expect(entry.text == "Cry" && entry.description == "30.0 mm")
        undoManager.undo()
        undoManager.undo()
        await parts.queue.waitUntilIdle()
        #expect(parts.parts(on: job.id).isEmpty)
        entry.endEditing()
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func typingWhileAPartWaitsToSaveUndoesFirst() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let spare = try await PartService(coordinator: coordinator).add(
            named: "Crystal 30.0 mm", to: nil)
        let parts = PartState(
            service: PartService(coordinator: coordinator),
            queue: EditQueue(coordinator: coordinator))
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { parts.parts.count == 1 }
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let entry = parts.entry(for: job.id)
        entry.beginEditing()

        // A slow write holds the library, as a backup export does, so each save waits until the
        // test lets it go. Two parts and then the spare are submitted, and the next name is
        // typed while all of them wait.
        let hold = LibraryHold()
        defer { hold.release() }
        let holdLibrary = Task.detached {
            try await coordinator.mutate { _, _, _ in hold.hold() }
        }
        try await waitUntil { hold.hasStarted }
        undoManager.beginUndoGrouping()
        let adding = parts.add(named: "Mainspring", to: job.id, undoManager: undoManager)
        undoManager.endUndoGrouping()
        undoManager.beginUndoGrouping()
        let addingNext = parts.add(named: "Hairspring", to: job.id, undoManager: undoManager)
        undoManager.endUndoGrouping()
        undoManager.beginUndoGrouping()
        let using = parts.useSpare(spare.id, on: job.id, undoManager: undoManager)
        undoManager.endUndoGrouping()
        #expect(parts.parts(on: job.id).isEmpty)
        undoManager.beginUndoGrouping()
        entry.change(to: "Gasket", undoManager: undoManager)
        undoManager.endUndoGrouping()
        hold.release()
        _ = try await holdLibrary.value
        #expect(await adding.didSave)
        #expect(await addingNext.didSave)
        #expect(await using.didSave)
        // The job's parts are in the order they were submitted.
        let submitted = ["Mainspring", "Hairspring", "Crystal 30.0 mm"]
        #expect(parts.parts(on: job.id).map(\.name) == submitted)
        let saved = try await coordinator.read { try PartQueries.fetchAll($0) }
        #expect(
            saved.filter { $0.jobID == job.id }.sorted { $0.position < $1.position }.map(\.name)
                == submitted)

        // ⌘Z undoes the typing, then the spare's use, then each part, in the order they were
        // done.
        #expect(undoManager.undoActionName == PartEntryWording.typingActionName)
        undoManager.undo()
        #expect(entry.text.isEmpty && parts.parts(on: job.id).count == 3)
        undoManager.undo()
        await parts.queue.waitUntilIdle()
        #expect(try await stored(spare.id, coordinator).isSpare)
        undoManager.undo()
        await parts.queue.waitUntilIdle()
        #expect(parts.parts(on: job.id).map(\.name) == ["Mainspring"])
        undoManager.undo()
        await parts.queue.waitUntilIdle()
        #expect(parts.parts(on: job.id).isEmpty)
        for _ in 0..<3 {
            undoManager.redo()
            await parts.queue.waitUntilIdle()
        }
        #expect(try await stored(spare.id, coordinator).jobID == job.id)
        #expect(parts.parts(on: job.id).map(\.name) == submitted)
        entry.endEditing()
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func typingWhileAStateChangeWaitsToSaveUndoesFirst() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let parts = PartState(
            service: PartService(coordinator: coordinator),
            queue: EditQueue(coordinator: coordinator), pause: PauseGate().pause)
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { !parts.isLoading }
        let part = try #require(await parts.add(named: "Mainspring", to: job.id)?.part)
        let facts = try #require(parts.facts(for: part.id))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        // A slow write holds the library until the test lets it go, so the click waits to save.
        // The part's name is typed while it waits.
        let hold = LibraryHold()
        defer { hold.release() }
        let holdLibrary = Task.detached {
            try await coordinator.mutate { _, _, _ in hold.hold() }
        }
        try await waitUntil { hold.hasStarted }
        undoManager.beginUndoGrouping()
        let clicking = parts.advance(part.id, undoManager: undoManager)
        undoManager.endUndoGrouping()
        facts.name.beginEditing()
        undoManager.beginUndoGrouping()
        facts.name.change(to: "Mainspring 1.10", undoManager: undoManager)
        undoManager.endUndoGrouping()
        hold.release()
        _ = try await holdLibrary.value
        #expect(await clicking.didSave)
        #expect(parts.part(part.id)?.stage == .ordered)

        // ⌘Z undoes the typing, then the click, in the order they were done.
        #expect(undoManager.undoActionName == "Part Name")
        undoManager.undo()
        await parts.queue.waitUntilIdle()
        #expect(facts.name.text == "Mainspring" && parts.part(part.id)?.stage == .ordered)
        #expect(undoManager.undoActionName == PartState.stageActionName)
        undoManager.undo()
        await parts.queue.waitUntilIdle()
        #expect(try await stored(part.id, coordinator).stage == .needed)
        facts.name.endEditing()

        // ⌘Z pressed while the click still waits to save undoes that click once it has saved,
        // and Shift-⌘Z gives it back.
        let secondHold = LibraryHold()
        defer { secondHold.release() }
        let holdAgain = Task.detached {
            try await coordinator.mutate { _, _, _ in secondHold.hold() }
        }
        try await waitUntil { secondHold.hasStarted }
        undoManager.beginUndoGrouping()
        let clickingAgain = parts.advance(part.id, undoManager: undoManager)
        undoManager.endUndoGrouping()
        undoManager.undo()
        secondHold.release()
        _ = try await holdAgain.value
        #expect(await clickingAgain.didSave)
        await parts.queue.waitUntilIdle()
        #expect(try await stored(part.id, coordinator).stage == .needed)
        undoManager.redo()
        await parts.queue.waitUntilIdle()
        #expect(try await stored(part.id, coordinator).stage == .ordered)

        // Choosing the state the part has adds no Undo step.
        undoManager.removeAllActions()
        undoManager.beginUndoGrouping()
        #expect(parts.setStage(.ordered, of: part.id, undoManager: undoManager) == nil)
        undoManager.endUndoGrouping()
        #expect(undoManager.undoActionName.isEmpty)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func quittingWaitsUntilEveryPartChangeHasSaved() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let parts = PartState(
            service: PartService(coordinator: coordinator),
            queue: EditQueue(coordinator: coordinator))
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { !parts.isLoading }
        let part = try #require(await parts.add(named: "Mainspring", to: job.id)?.part)

        // A slow write holds the library. A click and then an added part wait behind it, and
        // quitting is asked for while both wait.
        let hold = LibraryHold()
        defer { hold.release() }
        let holding = Task.detached { try await coordinator.mutate { _, _, _ in hold.hold() } }
        try await waitUntil { hold.hasStarted }
        let clicking = parts.advance(part.id)
        let adding = parts.add(named: "Crystal", to: job.id)
        let quitting = Task { await parts.queue.saveEverything() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(parts.isSaving && !parts.queue.isIdle)
        hold.release()
        _ = try await holding.value
        // Quitting goes ahead only once the click and the part have both saved.
        #expect(await quitting.value)
        #expect(clicking?.isPending == false && adding?.isPending == false)
        #expect(await clicking.didSave)
        #expect(await adding.didSave)
        #expect(!parts.isSaving && parts.parts(on: job.id).count == 2)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aDeletionWaitsForTypingThatDidNotSave() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let parts = PartState(
            service: PartService(coordinator: coordinator),
            queue: EditQueue(coordinator: coordinator), pause: PauseGate().pause)
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { !parts.isLoading }
        let part = try #require(await parts.add(named: "Mainspring", to: job.id)?.part)
        let facts = try #require(parts.facts(for: part.id))
        facts.name.beginEditing()
        facts.name.change(to: "Mainspring 1.10", undoManager: nil)

        try await JobTaskFixture.failWrites(coordinator, on: "part")
        #expect(await !parts.remove(part.id).didSave)
        #expect(parts.part(part.id) != nil && parts.saveError == PartState.failedFields)
        #expect(facts.name.text == "Mainspring 1.10" && facts.name.saveError != nil)
        try await JobTaskFixture.allowWrites(coordinator, on: "part")
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        let removing = parts.remove(part.id, undoManager: undoManager)
        undoManager.endUndoGrouping()
        #expect(await removing.didSave)
        undoManager.undo()
        await parts.queue.waitUntilIdle()
        // The typing saved before the part went, so Undo brings it back with the new name.
        #expect(try await stored(part.id, coordinator).name == "Mainspring 1.10")
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func spareSuggestionsMatchByNameAndOfferOnlySparesInHand() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        let sapphire = try await service.add(named: "Crystal, sapphire 30.0 mm", to: nil)
        let acrylic = try await service.add(named: "Acrylic crystal 29.5", to: nil)
        let toBuy = try await service.add(named: "Crystal 31 mm", to: nil)
        _ = try await service.setStage(toBuy.id, to: .ordered)
        let fitted = try await service.add(named: "Crystal 28 mm", to: nil)
        _ = try await service.setStage(fitted.id, to: .fitted)
        // A part in hand on a job is not a spare.
        let onJob = try await service.add(named: "Crystal for the job", to: job.id)
        _ = try await service.setStage(onJob.id, to: .inHand)
        let crown = try await service.add(named: "Crown Ø 5.3", to: nil)
        let parts = PartState(service: service, queue: EditQueue(coordinator: coordinator))
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { parts.parts.count == 6 }

        // The name has the text anywhere, in any case and without its accents.
        #expect(parts.spares(matching: " CRYSTAL ").map(\.id) == [acrylic.id, sapphire.id])
        #expect(parts.spares(matching: "sapphire").map(\.id) == [sapphire.id])
        #expect(parts.spares(matching: "CRŸSTAL").map(\.id) == [acrylic.id, sapphire.id])
        #expect(parts.spares(matching: "ø 5").map(\.id) == [crown.id])
        #expect(parts.spares(matching: "  ").isEmpty && parts.spares(matching: "hands").isEmpty)

        // The line you type in offers them only while you type. The arrows move the highlight,
        // and Up from the first one leaves none, so Return adds the typed part.
        let entry = parts.entry(for: job.id)
        #expect(parts.entry(for: job.id) === entry)
        entry.change(to: "crystal")
        #expect(entry.spares.isEmpty)
        entry.beginEditing()
        #expect(entry.spares.map(\.id) == [acrylic.id, sapphire.id] && entry.highlightedID == nil)
        entry.moveHighlight(down: true)
        #expect(entry.highlightedID == acrylic.id && !entry.isBlank)
        entry.moveHighlight(down: true)
        entry.moveHighlight(down: true)
        #expect(entry.highlightedID == sapphire.id)
        entry.moveHighlight(down: false)
        entry.moveHighlight(down: false)
        #expect(entry.highlightedID == nil)
        entry.moveHighlight(down: true)
        entry.change(to: "crystal, sapph")
        #expect(entry.highlightedID == nil && entry.spares.map(\.id) == [sapphire.id])
        entry.clear()
        #expect(entry.text.isEmpty && entry.isBlank)
        entry.endEditing()
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func usingASpareMovesItToTheJobAndUndoPutsItBackInTheDrawer() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        _ = try await service.add(named: "Mainspring", to: job.id)
        let spare = try await service.add(named: "Crystal 30.0 mm", to: nil)
        let parts = PartState(service: service, queue: EditQueue(coordinator: coordinator))
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { parts.parts.count == 2 }
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        undoManager.beginUndoGrouping()
        let using = parts.useSpare(spare.id, on: job.id, undoManager: undoManager)
        undoManager.endUndoGrouping()
        #expect(await using.didSave)
        #expect(parts.parts(on: job.id).map(\.name) == ["Mainspring", "Crystal 30.0 mm"])
        #expect(parts.spares(matching: "crystal").isEmpty)
        #expect(undoManager.undoActionName == PartState.spareActionName)
        // The spare keeps its state and day, so it is in hand on the job.
        let used = try await stored(spare.id, coordinator)
        #expect(used.stage == .inHand && used.inHandAt == spare.inHandAt)
        undoManager.undo()
        await parts.queue.waitUntilIdle()
        #expect(try await stored(spare.id, coordinator).isSpare)
        #expect(parts.spares(matching: "crystal").map(\.id) == [spare.id])
        undoManager.redo()
        await parts.queue.waitUntilIdle()
        #expect(try await stored(spare.id, coordinator).jobID == job.id)
        // A part that is no longer a spare can't be used again.
        #expect(parts.useSpare(spare.id, on: job.id) == nil)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func newPartInPartsMakesASpareWithTheCursorInItsName() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let parts = PartState(
            service: PartService(coordinator: coordinator),
            queue: EditQueue(coordinator: coordinator))
        #expect(parts.makeSpare() == nil)
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { !parts.isLoading }
        let spare = try #require(await parts.makeSpare()?.part)
        #expect(spare.isSpare && spare.name == "New Part" && spare.stage == .inHand)
        #expect(parts.selectedID == spare.id && parts.nameToFocus == spare.id)
        parts.nameFocused()
        #expect(parts.nameToFocus == nil)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func stepsAndPartsStayIndependent() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let steps = try await ChecklistService(coordinator: coordinator).save(
            [ChecklistStep(id: UUID(), text: "Fit the mainspring")], for: job.id
        ).after
        let parts = PartState(
            service: PartService(coordinator: coordinator),
            queue: EditQueue(coordinator: coordinator))
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { !parts.isLoading }
        let part = try #require(await parts.add(named: "Mainspring", to: job.id)?.part)
        for _ in 0..<3 { #expect(await parts.advance(part.id).didSave) }
        #expect(try await stored(part.id, coordinator).stage == .fitted)
        // A fitted part ticks no step.
        #expect(
            try await coordinator.read { try ChecklistQueries.ordered(for: job.id, in: $0) }
                == steps)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    private func stored(_ id: UUID, _ coordinator: LibraryCoordinator) async throws -> PartRecord {
        try #require(try await coordinator.read { try PartQueries.fetch(id, in: $0) })
    }
}

private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw PartTimeout()
}

nonisolated private struct PartTimeout: Error {}
