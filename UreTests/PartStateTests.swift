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
        let parts = PartState(service: PartService(coordinator: coordinator))
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { !parts.isLoading }
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        let part = try #require(await parts.add(named: "Mainspring", to: job.id))
        clock.set(1_000)
        undoManager.beginUndoGrouping()
        #expect(await parts.advance(part.id, undoManager: undoManager))
        undoManager.endUndoGrouping()
        #expect(parts.part(part.id)?.stage == .ordered)
        #expect(parts.part(part.id)?.orderedAt == clock.date(1_000))
        #expect(undoManager.undoActionName == PartState.stageActionName)

        clock.set(2_000)
        undoManager.undo()
        await parts.waitForChanges()
        var saved = try await stored(part.id, coordinator)
        #expect(saved.stage == .needed && saved.orderedAt == nil)
        #expect(parts.part(part.id)?.stage == .needed)
        // Redo gives back the state with the day it was given, not the day of the Redo.
        undoManager.redo()
        await parts.waitForChanges()
        saved = try await stored(part.id, coordinator)
        #expect(saved.stage == .ordered && saved.orderedAt == clock.date(1_000))

        // Two quick choices from the pop-up end at the last one, even when it is the state the
        // part had before the first saved.
        _ = await parts.setStage(.needed, of: part.id)
        let toOrdered = Task { await parts.setStage(.ordered, of: part.id) }
        let backToNeeded = Task { await parts.setStage(.needed, of: part.id) }
        _ = await (toOrdered.value, backToNeeded.value)
        #expect(try await stored(part.id, coordinator).stage == .needed)
        _ = await parts.setStage(.ordered, of: part.id)

        // Two quick clicks move the part on twice, each with its own Undo step.
        async let firstClick = parts.advance(part.id, undoManager: nil)
        async let secondClick = parts.advance(part.id, undoManager: nil)
        _ = await (firstClick, secondClick)
        #expect(try await stored(part.id, coordinator).stage == .fitted)
        _ = await parts.setStage(.ordered, of: part.id)

        // Each click is its own Undo step, and a fitted part stays fitted.
        for _ in 0..<2 {
            undoManager.beginUndoGrouping()
            _ = await parts.advance(part.id, undoManager: undoManager)
            undoManager.endUndoGrouping()
        }
        #expect(parts.part(part.id)?.stage == .fitted)
        #expect(!(await parts.advance(part.id, undoManager: undoManager)))
        undoManager.undo()
        await parts.waitForChanges()
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
        let parts = PartState(service: PartService(coordinator: coordinator))
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { !parts.isLoading }
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        #expect(await parts.add(named: "  ", to: job.id) == nil)
        undoManager.beginUndoGrouping()
        let mainspring = try #require(
            await parts.add(named: "Mainspring", to: job.id, undoManager: undoManager))
        undoManager.endUndoGrouping()
        let crystal = try #require(await parts.add(named: "Crystal", to: job.id))
        #expect(parts.parts(on: job.id).map(\.name) == ["Mainspring", "Crystal"])
        #expect(undoManager.undoActionName == PartState.addActionName)
        undoManager.undo()
        await parts.waitForChanges()
        #expect(parts.parts(on: job.id).map(\.id) == [crystal.id])
        undoManager.redo()
        await parts.waitForChanges()
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
        #expect(await parts.remove(crystal.id, undoManager: undoManager))
        undoManager.endUndoGrouping()
        #expect(parts.selectedID == nil && parts.part(crystal.id) == nil)
        #expect(undoManager.undoActionName == PartState.removeActionName)
        #expect(try await coordinator.read { try PartQueries.fetch(crystal.id, in: $0) } == nil)
        undoManager.undo()
        await parts.waitForChanges()
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
        #expect(parts.hasUnsavedFacts)
        undoManager.beginUndoGrouping()
        #expect(await parts.remove(crystal.id, undoManager: undoManager))
        undoManager.endUndoGrouping()
        #expect(!parts.hasUnsavedFacts && parts.facts(for: crystal.id) == nil)
        undoManager.undo()
        await parts.waitForChanges()
        try await waitUntil { parts.facts(for: crystal.id) != nil }
        #expect(parts.facts(for: crystal.id)?.quantity.text == "1" && !parts.hasUnsavedFacts)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aNameThatDidNotSaveStaysWithTryAgainWhileTheNextIsTyped() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let parts = PartState(service: PartService(coordinator: coordinator))
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
        #expect(!(await parts.submit(crystal, spare: nil, on: entry)))
        #expect(entry.unsaved == [crystal] && entry.text == "Crys" && parts.hasUnsavedFacts)
        #expect(!(await parts.submit(PartEntryText(name: "Gasket"), spare: nil, on: entry)))
        #expect(!(await parts.retryUnsaved(entry)))
        #expect(entry.unsaved.map(\.name) == ["Crystal", "Gasket"])
        // Quitting tries them again and says that they did not save.
        #expect(!(await parts.saveAllFacts()))
        #expect(entry.unsaved.map(\.name) == ["Crystal", "Gasket"])
        try await JobTaskFixture.allowWrites(coordinator, on: "part")
        // Two Try Agains at once add each name once.
        async let first = parts.retryUnsaved(entry)
        async let second = parts.retryUnsaved(entry)
        _ = await (first, second)
        #expect(entry.unsaved.isEmpty && !parts.hasUnsavedFacts)
        #expect(await parts.saveAllFacts())
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
        let parts = PartState(service: PartService(coordinator: coordinator))
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
        #expect(await parts.submit(typed, spare: nil, on: entry, undoManager: undoManager))
        undoManager.endUndoGrouping()
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
        await parts.waitForChanges()
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
        let parts = PartState(service: PartService(coordinator: coordinator))
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
        let adding = Task {
            await parts.add(named: "Mainspring", to: job.id, undoManager: undoManager)
        }
        for _ in 0..<5 { await Task.yield() }
        undoManager.endUndoGrouping()
        undoManager.beginUndoGrouping()
        let addingNext = Task {
            await parts.add(named: "Hairspring", to: job.id, undoManager: undoManager)
        }
        for _ in 0..<5 { await Task.yield() }
        undoManager.endUndoGrouping()
        undoManager.beginUndoGrouping()
        let using = Task { await parts.useSpare(spare.id, on: job.id, undoManager: undoManager) }
        for _ in 0..<5 { await Task.yield() }
        undoManager.endUndoGrouping()
        #expect(parts.parts(on: job.id).isEmpty)
        undoManager.beginUndoGrouping()
        entry.change(to: "Gasket", undoManager: undoManager)
        undoManager.endUndoGrouping()
        hold.release()
        _ = try await holdLibrary.value
        let added = await adding.value
        let addedNext = await addingNext.value
        let used = await using.value
        #expect(added != nil && addedNext != nil && used)
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
        await parts.waitForChanges()
        #expect(try await stored(spare.id, coordinator).isSpare)
        undoManager.undo()
        await parts.waitForChanges()
        #expect(parts.parts(on: job.id).map(\.name) == ["Mainspring"])
        undoManager.undo()
        await parts.waitForChanges()
        #expect(parts.parts(on: job.id).isEmpty)
        for _ in 0..<3 {
            undoManager.redo()
            await parts.waitForChanges()
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
            service: PartService(coordinator: coordinator), pause: PauseGate().pause)
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { !parts.isLoading }
        let part = try #require(await parts.add(named: "Mainspring", to: job.id))
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
        let clicking = Task { await parts.advance(part.id, undoManager: undoManager) }
        for _ in 0..<5 { await Task.yield() }
        undoManager.endUndoGrouping()
        facts.name.beginEditing()
        undoManager.beginUndoGrouping()
        facts.name.change(to: "Mainspring 1.10", undoManager: undoManager)
        undoManager.endUndoGrouping()
        hold.release()
        _ = try await holdLibrary.value
        #expect(await clicking.value)
        #expect(parts.part(part.id)?.stage == .ordered)

        // ⌘Z undoes the typing, then the click, in the order they were done.
        #expect(undoManager.undoActionName == "Part Name")
        undoManager.undo()
        #expect(facts.name.text == "Mainspring" && parts.part(part.id)?.stage == .ordered)
        #expect(undoManager.undoActionName == PartState.stageActionName)
        undoManager.undo()
        await parts.waitForChanges()
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
        let clickingAgain = Task { await parts.advance(part.id, undoManager: undoManager) }
        for _ in 0..<5 { await Task.yield() }
        undoManager.endUndoGrouping()
        undoManager.undo()
        secondHold.release()
        _ = try await holdAgain.value
        #expect(await clickingAgain.value)
        await parts.waitForChanges()
        #expect(try await stored(part.id, coordinator).stage == .needed)
        undoManager.redo()
        await parts.waitForChanges()
        #expect(try await stored(part.id, coordinator).stage == .ordered)

        // Choosing the state the part has adds no Undo step.
        undoManager.removeAllActions()
        undoManager.beginUndoGrouping()
        #expect(await parts.setStage(.ordered, of: part.id, undoManager: undoManager))
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
        let parts = PartState(service: PartService(coordinator: coordinator))
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { !parts.isLoading }
        let part = try #require(await parts.add(named: "Mainspring", to: job.id))

        // Two holds on the library, as two slow writes. A click waits behind the first and an
        // added part behind the second, so the click saves while the part still waits. All of
        // them run at one priority, so the library takes them in the order they came.
        let firstHold = LibraryHold()
        let secondHold = LibraryHold()
        defer {
            firstHold.release()
            secondHold.release()
        }
        let holdingFirst = Task.detached(priority: .medium) {
            try await coordinator.mutate { _, _, _ in firstHold.hold() }
        }
        try await waitUntil { firstHold.hasStarted }
        let clicking = Task(priority: .medium) { await parts.advance(part.id) }
        try await Task.sleep(for: .milliseconds(100))
        let holdingSecond = Task.detached(priority: .medium) {
            try await coordinator.mutate { _, _, _ in secondHold.hold() }
        }
        try await Task.sleep(for: .milliseconds(100))
        let adding = Task(priority: .medium) { await parts.add(named: "Crystal", to: job.id) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(parts.isSaving)

        firstHold.release()
        _ = try await holdingFirst.value
        try await waitUntil { parts.part(part.id)?.stage == .ordered }
        try await waitUntil { secondHold.hasStarted }
        // The part waits to save, so quitting still waits.
        #expect(parts.isSaving && parts.parts(on: job.id).count == 1)
        secondHold.release()
        _ = try await holdingSecond.value
        #expect(await clicking.value)
        #expect(await adding.value != nil)
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
            service: PartService(coordinator: coordinator), pause: PauseGate().pause)
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { !parts.isLoading }
        let part = try #require(await parts.add(named: "Mainspring", to: job.id))
        let facts = try #require(parts.facts(for: part.id))
        facts.name.beginEditing()
        facts.name.change(to: "Mainspring 1.10", undoManager: nil)

        try await JobTaskFixture.failWrites(coordinator, on: "part")
        #expect(!(await parts.remove(part.id)))
        #expect(parts.part(part.id) != nil && parts.saveError != nil)
        #expect(facts.name.text == "Mainspring 1.10" && facts.name.saveError != nil)
        try await JobTaskFixture.allowWrites(coordinator, on: "part")
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        #expect(await parts.remove(part.id, undoManager: undoManager))
        undoManager.endUndoGrouping()
        undoManager.undo()
        await parts.waitForChanges()
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
        let parts = PartState(service: service)
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
        let parts = PartState(service: service)
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { parts.parts.count == 2 }
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        undoManager.beginUndoGrouping()
        #expect(await parts.useSpare(spare.id, on: job.id, undoManager: undoManager))
        undoManager.endUndoGrouping()
        #expect(parts.parts(on: job.id).map(\.name) == ["Mainspring", "Crystal 30.0 mm"])
        #expect(parts.spares(matching: "crystal").isEmpty)
        #expect(undoManager.undoActionName == PartState.spareActionName)
        // The spare keeps its state and day, so it is in hand on the job.
        let used = try await stored(spare.id, coordinator)
        #expect(used.stage == .inHand && used.inHandAt == spare.inHandAt)
        undoManager.undo()
        await parts.waitForChanges()
        #expect(try await stored(spare.id, coordinator).isSpare)
        #expect(parts.spares(matching: "crystal").map(\.id) == [spare.id])
        undoManager.redo()
        await parts.waitForChanges()
        #expect(try await stored(spare.id, coordinator).jobID == job.id)
        // A part that is no longer a spare can't be used again.
        #expect(!(await parts.useSpare(spare.id, on: job.id)))
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
        let parts = PartState(service: PartService(coordinator: coordinator))
        #expect(await parts.makeSpare() == nil)
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { !parts.isLoading }
        let spare = try #require(await parts.makeSpare())
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
            [ChecklistStep(id: UUID(), text: "Fit the mainspring")], for: job.id)
        let parts = PartState(service: PartService(coordinator: coordinator))
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { !parts.isLoading }
        let part = try #require(await parts.add(named: "Mainspring", to: job.id))
        for _ in 0..<3 { _ = await parts.advance(part.id) }
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

// A write that holds the library until the test lets it go, as a slow write does.
nonisolated private final class LibraryHold: Sendable {
    private let started = Mutex(false)
    private let gate = DispatchSemaphore(value: 0)

    var hasStarted: Bool { started.withLock { $0 } }

    func hold() {
        started.withLock { $0 = true }
        gate.wait()
    }

    func release() { gate.signal() }
}
