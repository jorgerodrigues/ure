import Foundation
import GRDB
import Testing

@testable import Ure

struct CaliberStateTests {
    @Test(.timeLimit(.minutes(1)))
    func unavailableLibraryShowsLoadErrorAndRetryRecovers() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        let state = CaliberState(service: CaliberService(coordinator: coordinator))
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
    func committedChangesRefreshListAndDetailWithoutReplacingAnOpenDraft() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let service = CaliberService(coordinator: coordinator)
        let state = CaliberState(service: service)
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { !state.isLoading }
        var draft = CaliberDraft()
        draft.designation = "Saved caliber"
        let saved = try await service.save(draft, editing: nil)
        try await waitUntil { state.calibers.contains(saved) }
        state.select(saved.id)
        state.edit()
        state.draft?.designation = "Keep my draft"
        draft.designation = "Committed update"
        let updated = try await service.save(draft, editing: saved.id)
        try await waitUntil { state.selectedCaliber == updated }
        #expect(state.draft?.designation == "Keep my draft")
        state.searchText = "committed"
        #expect(state.filteredCalibers == [updated])
        state.cancel()
        #expect(state.selectedCaliber == updated)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test
    func cancelDiscardsNewAndEditedDraftsWithoutWriting() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let state = CaliberState(service: CaliberService(coordinator: coordinator))
        state.create()
        state.draft?.designation = "Unsaved"
        state.cancel()
        #expect(state.draft == nil)
        #expect(!state.hasUnsavedChanges)
        #expect(try await coordinator.read(CaliberQueries.fetchAll).isEmpty)
        state.create()
        state.draft?.designation = "Saved"
        #expect(await state.save())
        let saved = try #require(state.selectedCaliber)
        state.edit()
        state.draft?.designation = "Unsaved edit"
        state.cancel()
        #expect(state.selectedCaliber == saved)
        #expect(try await coordinator.read(CaliberQueries.fetchAll) == [saved])
        try await coordinator.close()
    }

    @Test
    func stayDiscardAndSaveProtectPendingNavigation() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let state = CaliberState(service: CaliberService(coordinator: coordinator))
        var navigated = false
        state.create()
        state.draft?.designation = "Draft caliber"
        state.requestNavigation { navigated = true }
        #expect(state.showsUnsavedChanges)
        #expect(!navigated)
        state.stay()
        #expect(state.draft?.designation == "Draft caliber")
        #expect(!navigated)
        state.requestNavigation { navigated = true }
        await state.saveAndContinue()
        #expect(navigated)
        #expect(state.draft == nil)
        #expect(state.selectedCaliber?.designation == "Draft caliber")
        #expect(!state.showsUnsavedChanges)
        state.edit()
        state.draft?.designation = "Discarded edit"
        navigated = false
        state.requestNavigation { navigated = true }
        state.discardAndContinue()
        #expect(navigated)
        #expect(state.selectedCaliber?.designation == "Draft caliber")
        #expect(
            try await coordinator.read(CaliberQueries.fetchAll).first?.designation
                == "Draft caliber")
        try await coordinator.close()
    }

    @Test
    func failedSaveKeepsDraftAndCancelsClosureUntilRetrySucceeds() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: """
                    CREATE TRIGGER failCaliberInsert BEFORE INSERT ON caliber
                    BEGIN SELECT RAISE(ABORT, 'fixture disk failure'); END
                    """)
        }
        let state = CaliberState(service: CaliberService(coordinator: coordinator))
        state.create()
        state.draft?.designation = "Keep this draft"
        let draft = state.draft
        var closed = false
        var cancelled = false
        state.requestNavigation({ closed = true }, onCancel: { cancelled = true })
        await state.saveAndContinue()
        #expect(!closed)
        #expect(cancelled)
        #expect(state.draft == draft)
        #expect(state.saveError != nil)
        #expect(!state.isSaving)
        #expect(try await coordinator.read(CaliberQueries.fetchAll).isEmpty)
        try await coordinator.mutate { db, _, _ in
            try db.execute(sql: "DROP TRIGGER failCaliberInsert")
        }
        state.requestNavigation { closed = true }
        await state.saveAndContinue()
        #expect(closed)
        #expect(state.selectedCaliber?.designation == "Keep this draft")
        #expect(state.saveError == nil)
        try await coordinator.close()
    }

    @Test
    func validationErrorsKeepTheDraftAndClearAfterCorrection() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let state = CaliberState(service: CaliberService(coordinator: coordinator))
        state.create()
        state.draft?.beatRate = "-18"
        #expect(!(await state.save()))
        #expect(state.fieldErrors[.designation] != nil)
        #expect(state.fieldErrors[.beatRate] != nil)
        #expect(state.draft?.beatRate == "-18")
        state.draft?.designation = "Caliber"
        state.draft?.beatRate = "18"
        #expect(await state.save())
        #expect(state.fieldErrors.isEmpty)
        #expect(state.saveError == nil)
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func repeatedSaveAndNavigationCannotInterruptAPendingWrite() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let started = AsyncStream<Void>.makeStream()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let blocker = Task {
            try await coordinator.mutate { _, _, _ in
                started.continuation.yield(())
                gate.wait()
            }
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        let state = CaliberState(service: CaliberService(coordinator: coordinator))
        state.create()
        state.draft?.designation = "One caliber"
        let saving = Task { await state.save() }
        try await waitUntil { state.isSaving }
        #expect(!(await state.save()))
        var navigated = false
        state.requestNavigation { navigated = true }
        state.cancel()
        #expect(!navigated)
        #expect(state.draft?.designation == "One caliber")
        gate.signal()
        try await blocker.value
        #expect(await saving.value)
        #expect(try await coordinator.read(CaliberQueries.fetchAll).count == 1)
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
