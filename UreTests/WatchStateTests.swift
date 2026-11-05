import Foundation
import GRDB
import Testing

@testable import Ure

struct WatchStateTests {
    private let unitedStates = Locale(identifier: "en_US")

    @Test(.timeLimit(.minutes(1)))
    func unavailableLibraryShowsLoadErrorAndRetryRecovers() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        let state = WatchState(service: WatchService(coordinator: coordinator))
        await state.observe()
        #expect(!state.isLoading && state.loadError != nil)
        _ = try await coordinator.open()
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { !state.isLoading && state.loadError == nil }
        #expect(state.watches.isEmpty)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func newWatchIsSelectedWithTheCursorInItsName() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let state = WatchState(service: WatchService(coordinator: coordinator))
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { !state.isLoading }
        state.searchText = "Nothing matches"
        #expect(await state.create())
        let watch = try #require(state.selectedWatch)
        #expect(watch.name == "New Watch" && state.nameToFocus == watch.id)
        #expect(state.searchText.isEmpty && state.filteredWatches == [watch])
        #expect(state.facts(for: watch.id)?.name.text == "New Watch")
        state.nameFocused()
        #expect(state.nameToFocus == nil)
        try await waitUntil { state.watches.count == 1 }
        #expect(try await coordinator.read(WatchQueries.fetchAll) == [watch])
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
        let caliber = try await CaliberService(coordinator: coordinator).create(named: "552")
        let service = WatchService(coordinator: coordinator)
        let watch = try await service.create(named: "Seamaster")
        let state = WatchState(service: service, locale: unitedStates, pause: PauseGate().pause)
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { state.watches == [watch] }
        let facts = try #require(state.facts(for: watch.id))
        let typed: [(FactField, String, String)] = [
            (facts.brand, " Omega ", "Omega"), (facts.model, "Seamaster 30", "Seamaster 30"),
            (facts.reference, "2846-2848", "2846-2848"), (facts.serial, "0012345", "0012345"),
            (facts.year, "About 1958", "About 1958"),
            (facts.caseMaterial, "Stainless steel", "Stainless steel"),
            (facts.diameter, "35mm", "35 mm"), (facts.lugWidth, "18.0 mm", "18 mm"),
            (facts.owner, "Ana Ribeiro", "Ana Ribeiro"),
            (facts.contact, "+351 912 480 117", "+351 912 480 117"),
        ]
        for (field, text, shown) in typed {
            field.beginEditing()
            field.change(to: text, undoManager: nil)
            #expect(state.hasUnsavedFacts)
            field.endEditing()
            try await waitUntil { field.text == shown && !field.hasUnsavedChanges }
        }
        facts.caliber.choose(caliber.id.uuidString, undoManager: nil)
        try await waitUntil { !facts.caliber.hasUnsavedChanges }
        let saved = try #require(try await coordinator.read(WatchQueries.fetchAll).first)
        #expect(saved.brand == "Omega" && saved.model == "Seamaster 30")
        #expect(saved.caseReference == "2846-2848" && saved.serial == "0012345")
        #expect(saved.approximateYear == "About 1958" && saved.caseMaterial == "Stainless steel")
        #expect(saved.caseDiameter == 35 && saved.lugWidth == 18)
        #expect(saved.owner == "Ana Ribeiro" && saved.contact == "+351 912 480 117")
        #expect(saved.caliberID == caliber.id && facts.caliber.text == caliber.id.uuidString)
        #expect(state.brands == [FactSuggestion(text: "Omega", detail: "1 watch")])

        facts.diameter.beginEditing()
        facts.diameter.change(to: "big", undoManager: nil)
        facts.diameter.endEditing()
        #expect(facts.diameter.problem == "Enter a number, such as 38 mm.")
        #expect(facts.diameter.text == "big" && facts.diameter.hasUnsavedChanges)
        #expect(try await coordinator.read(WatchQueries.fetchAll).first?.caseDiameter == 35)
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
        let service = WatchService(coordinator: coordinator)
        let watch = try await service.create(named: "Seamaster")
        let state = WatchState(service: service, locale: unitedStates, pause: PauseGate().pause)
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { state.watches == [watch] }
        let field = try #require(state.facts(for: watch.id)?.owner)
        let undo = UndoManager()
        undo.groupsByEvent = false
        field.beginEditing()
        undo.beginUndoGrouping()
        field.change(to: "Ana Ribeiro", undoManager: undo)
        undo.endUndoGrouping()
        field.endEditing()
        try await waitUntil { !field.hasUnsavedChanges }
        #expect(try await coordinator.read(WatchQueries.fetchAll).first?.owner == "Ana Ribeiro")
        #expect(undo.undoMenuItemTitle == "Undo Owner")
        undo.undo()
        try await waitUntil { field.text.isEmpty && !field.hasUnsavedChanges }
        #expect(try await coordinator.read(WatchQueries.fetchAll).first?.owner == nil)
        undo.redo()
        try await waitUntil { field.text == "Ana Ribeiro" && !field.hasUnsavedChanges }
        #expect(try await coordinator.read(WatchQueries.fetchAll).first?.owner == "Ana Ribeiro")
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aWatchWithAnOpenJobArchivesAndUndoOrUnarchiveBringsItBack() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let other = try await WatchService(coordinator: coordinator).create(named: "Another watch")
        let state = WatchState(service: WatchService(coordinator: coordinator))
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { state.watches.count == 2 }
        let history = try await coordinator.read(ActivityQueries.fetchAll)
        state.select(job.watchID)
        #expect(!state.showsArchived)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        #expect(await state.toggleArchive(undoManager: undo))
        undo.endUndoGrouping()
        #expect(state.selectedWatch?.archivedAt != nil && state.selectedID == job.watchID)
        #expect(state.filteredWatches.map(\.id) == [other.id])
        #expect(state.archivedWatches.map(\.id) == [job.watchID])
        #expect(state.showsArchived && state.activeCount == 1 && state.archivedCount == 1)
        #expect(undo.undoMenuItemTitle == "Undo Archive Watch")
        #expect(try await archivedAt(job.watchID, coordinator) != nil)

        undo.undo()
        await state.waitForArchiveChanges()
        #expect(try await archivedAt(job.watchID, coordinator) == nil)
        #expect(state.filteredWatches.count == 2 && state.archivedWatches.isEmpty)
        #expect(undo.redoMenuItemTitle == "Redo Archive Watch")
        undo.redo()
        await state.waitForArchiveChanges()
        #expect(try await archivedAt(job.watchID, coordinator) != nil)
        #expect(undo.undoMenuItemTitle == "Undo Archive Watch")

        undo.beginUndoGrouping()
        #expect(await state.toggleArchive(undoManager: undo))
        undo.endUndoGrouping()
        #expect(try await archivedAt(job.watchID, coordinator) == nil)
        #expect(undo.undoMenuItemTitle == "Undo Unarchive Watch")
        #expect(try await coordinator.read { try JobQueries.fetch(job.id, in: $0) } == job)
        #expect(try await coordinator.read(ActivityQueries.fetchAll) == history)
        #expect(try await coordinator.read(WorkshopQueries.fetch).map(\.id) == [job.id])
        state.discardUndo()
        #expect(!undo.canUndo)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func archivingWaitsForFactsStillSavingAndStopsAtAFactThatIsNotValid() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let service = WatchService(coordinator: coordinator)
        let watch = try await service.create(named: "Seamaster")
        let state = WatchState(service: service, locale: unitedStates, pause: PauseGate().pause)
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { state.watches == [watch] }
        state.select(watch.id)
        let facts = try #require(state.facts(for: watch.id))
        facts.brand.beginEditing()
        facts.brand.change(to: "Omega", undoManager: nil)
        #expect(await state.toggleArchive())
        let archived = try #require(try await coordinator.read(WatchQueries.fetchAll).first)
        #expect(archived.brand == "Omega" && archived.archivedAt != nil)
        #expect(!facts.brand.hasUnsavedChanges && facts.brand.saveError == nil)
        await #expect(throws: ArchiveError.archived) {
            try await service.update(watch.id, .brand("Changed while archived"))
        }
        #expect(await state.toggleArchive())
        facts.lugWidth.beginEditing()
        facts.lugWidth.change(to: "wide", undoManager: nil)
        facts.lugWidth.endEditing()
        #expect(await !state.toggleArchive())
        #expect(state.saveError != nil && facts.lugWidth.text == "wide")
        #expect(try await coordinator.read(WatchQueries.fetchAll).first?.archivedAt == nil)
        facts.lugWidth.beginEditing()
        facts.lugWidth.change(to: "20", undoManager: nil)
        #expect(await state.toggleArchive())
        let saved = try #require(try await coordinator.read(WatchQueries.fetchAll).first)
        #expect(saved.lugWidth == 20 && saved.archivedAt != nil && state.saveError == nil)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    private func archivedAt(_ id: UUID, _ coordinator: LibraryCoordinator) async throws -> Date? {
        try await coordinator.read { try WatchQueries.fetch(id, in: $0)?.archivedAt }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WatchObservationTimeout()
    }
}

nonisolated private struct WatchObservationTimeout: Error {}
