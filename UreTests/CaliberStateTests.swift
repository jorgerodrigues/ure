import Foundation
import GRDB
import Testing

@testable import Ure

struct CaliberStateTests {
    private let unitedStates = Locale(identifier: "en_US")

    @Test(.timeLimit(.minutes(1)))
    func unavailableLibraryShowsLoadErrorAndRetryRecovers() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        let queue = EditQueue(coordinator: coordinator)
        let state = CaliberState(queue: queue)
        await state.observe()
        #expect(!state.isLoading)
        #expect(state.loadError != nil)
        _ = try await coordinator.open()
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { !state.isLoading && state.loadError == nil }
        #expect(state.calibers.isEmpty)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func newCaliberIsSelectedWithTheCursorInItsName() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let queue = EditQueue(coordinator: coordinator)
        let state = CaliberState(queue: queue)
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { !state.isLoading }
        state.searchText = "Nothing matches"
        #expect(await state.create().didSave)
        let caliber = try #require(state.selectedCaliber)
        #expect(caliber.designation == "New Caliber" && state.nameToFocus == caliber.id)
        #expect(state.searchText.isEmpty && state.filteredCalibers == [caliber])
        #expect(state.facts(for: caliber.id)?.name.text == "New Caliber")
        state.nameFocused()
        #expect(state.nameToFocus == nil)
        try await waitUntil { state.calibers.count == 1 }
        #expect(try await coordinator.read(CaliberQueries.fetchAll) == [caliber])
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func everyFactSavesWithoutAButtonAndShowsInTheRegionFormat() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let gate = PauseGate()
        let service = CaliberService(coordinator: coordinator)
        let queue = EditQueue(coordinator: coordinator)
        let state = CaliberState(queue: queue, locale: unitedStates, pause: gate.pause)
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { !state.isLoading }
        #expect(await state.create().didSave)
        let id = try #require(state.selectedID)
        let facts = try #require(state.facts(for: id))
        let typed: [(FactField, String, String)] = [
            (facts.name, "552", "552"), (facts.maker, " Omega ", "Omega"),
            (facts.winding, "auto", "Automatic"), (facts.beatRate, "19800", "19,800 vph"),
            (facts.jewels, "24 jewels", "24"), (facts.powerReserve, "50h", "50 h"),
            (facts.liftAngle, "52.5", "52.5°"),
        ]
        for (field, text, shown) in typed {
            field.beginEditing()
            field.change(to: text, undoManager: nil)
            #expect(queue.hasUnsavedTyping)
            field.endEditing()
            try await waitUntil { field.text == shown && !field.hasUnsavedChanges }
        }
        let saved = try #require(try await coordinator.read(CaliberQueries.fetchAll).first)
        #expect(saved.designation == "552" && saved.manufacturer == "Omega")
        #expect(saved.winding == .automatic && saved.beatRate == 19_800)
        #expect(saved.jewelCount == 24 && saved.powerReserve == 50 && saved.liftAngle == 52.5)
        try await waitUntil { state.selectedCaliber == saved }
        #expect(
            state.makers == [FactSuggestion(text: "Omega", detail: "1 caliber")]
                && !queue.hasUnsavedTyping)

        facts.jewels.beginEditing()
        facts.jewels.change(to: "2", undoManager: nil)
        _ = try await service.update(id, .jewels(17))
        _ = try await service.update(id, .maker("Omega SA"))
        try await waitUntil { facts.maker.text == "Omega SA" }
        #expect(facts.jewels.text == "2")
        facts.jewels.endEditing()
        try await waitUntil { !facts.jewels.hasUnsavedChanges }
        #expect(try await coordinator.read(CaliberQueries.fetchAll).first?.jewelCount == 2)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func invalidNumberStaysOnScreenAndTheCaliberKeepsItsLastGoodValue() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let service = CaliberService(coordinator: coordinator)
        let caliber = try await service.update(
            try await service.create(named: "552").id, .beatRate(19_800)
        ).after
        let queue = EditQueue(coordinator: coordinator)
        let state = CaliberState(
            queue: queue, locale: unitedStates, pause: PauseGate().pause)
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { state.calibers == [caliber] }
        let field = try #require(state.facts(for: caliber.id)?.beatRate)
        #expect(field.text == "19,800 vph")
        field.beginEditing()
        field.change(to: "19,80", undoManager: nil)
        field.endEditing()
        #expect(field.problem == "Enter a number, such as 28,800 vph.")
        #expect(field.text == "19,80" && queue.hasUnsavedTyping)
        #expect(await queue.saveEverything() == .textNotValid)
        #expect(try await coordinator.read(CaliberQueries.fetchAll) == [caliber])
        _ = try await service.update(caliber.id, .name("552 Elaboré"))
        try await waitUntil { state.calibers.first?.designation == "552 Elaboré" }
        #expect(field.text == "19,80")
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func undoChangesASavedFactBackAndRedoSavesItAgain() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let service = CaliberService(coordinator: coordinator)
        let caliber = try await service.create(named: "552")
        let queue = EditQueue(coordinator: coordinator)
        let state = CaliberState(
            queue: queue, locale: unitedStates, pause: PauseGate().pause)
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { state.calibers == [caliber] }
        let field = try #require(state.facts(for: caliber.id)?.liftAngle)
        let undo = UndoManager()
        undo.groupsByEvent = false
        field.beginEditing()
        undo.beginUndoGrouping()
        field.change(to: "52", undoManager: undo)
        undo.endUndoGrouping()
        field.endEditing()
        try await waitUntil { field.text == "52°" && !field.hasUnsavedChanges }
        #expect(try await coordinator.read(CaliberQueries.fetchAll).first?.liftAngle == 52)
        #expect(undo.undoMenuItemTitle == "Undo Lift Angle")
        undo.undo()
        try await waitUntil { field.text.isEmpty && !field.hasUnsavedChanges }
        #expect(try await coordinator.read(CaliberQueries.fetchAll).first?.liftAngle == nil)
        undo.redo()
        try await waitUntil { field.text == "52°" && !field.hasUnsavedChanges }
        #expect(try await coordinator.read(CaliberQueries.fetchAll).first?.liftAngle == 52)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func archivingWaitsForFactsStillSavingAndThenStopsChanges() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let service = CaliberService(coordinator: coordinator)
        let caliber = try await service.create(named: "552")
        let queue = EditQueue(coordinator: coordinator)
        let state = CaliberState(
            queue: queue, locale: unitedStates, pause: PauseGate().pause)
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { state.calibers == [caliber] }
        state.select(caliber.id)
        let maker = try #require(state.facts(for: caliber.id)?.maker)
        maker.beginEditing()
        maker.change(to: "Omega", undoManager: nil)
        #expect(await state.toggleArchive().didSave)
        let archived = try #require(try await coordinator.read(CaliberQueries.fetchAll).first)
        #expect(archived.manufacturer == "Omega" && archived.archivedAt != nil)
        #expect(!maker.hasUnsavedChanges)
        await #expect(throws: ArchiveError.archived) {
            try await service.update(caliber.id, .maker("Changed while archived"))
        }
        #expect(await state.toggleArchive().didSave)
        let beatRate = try #require(state.facts(for: caliber.id)?.beatRate)
        beatRate.beginEditing()
        beatRate.change(to: "fast", undoManager: nil)
        beatRate.endEditing()
        #expect(await !state.toggleArchive().didSave)
        #expect(state.refusal != nil && beatRate.text == "fast")
        #expect(try await coordinator.read(CaliberQueries.fetchAll).first?.archivedAt == nil)
        beatRate.beginEditing()
        beatRate.change(to: "28800", undoManager: nil)
        #expect(await state.toggleArchive().didSave)
        let saved = try #require(try await coordinator.read(CaliberQueries.fetchAll).first)
        #expect(saved.beatRate == 28_800 && saved.archivedAt != nil && state.refusal == nil)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func factsSaveWhenLeavingOrQuittingWithoutTheDraftQuestion() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let service = CaliberService(coordinator: coordinator)
        let caliber = try await service.create(named: "552")
        let editing = EditingFixture.make(coordinator, pause: PauseGate().pause)
        let calibers = editing.calibers
        let observation = Task { await calibers.observe() }
        defer { observation.cancel() }
        try await waitUntil { calibers.calibers == [caliber] }
        let facts = try #require(calibers.facts(for: caliber.id))
        facts.name.beginEditing()
        facts.name.change(to: "552 typed before leaving", undoManager: nil)
        #expect(editing.hasUnsavedFields)
        var navigated = false
        editing.requestNavigation { navigated = true }
        #expect(navigated)
        try await waitUntil { !facts.name.hasUnsavedChanges }
        #expect(
            try await coordinator.read(CaliberQueries.fetchAll).first?.designation
                == "552 typed before leaving")
        facts.powerReserve.beginEditing()
        facts.powerReserve.change(to: "42", undoManager: nil)
        #expect(await editing.saveAllFields() == .saved)
        #expect(try await coordinator.read(CaliberQueries.fetchAll).first?.powerReserve == 42)
        #expect(!editing.hasUnsavedFields)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CaliberObservationTimeout()
    }
}

nonisolated private struct CaliberObservationTimeout: Error {}
