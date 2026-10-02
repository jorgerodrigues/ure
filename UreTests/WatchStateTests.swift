import Foundation
import GRDB
import Testing

@testable import Ure

struct WatchStateTests {
    @Test(.timeLimit(.minutes(1)))
    func committedChangesRefreshListAndDetailWithoutReplacingAnOpenDraft() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let service = WatchService(coordinator: coordinator)
        let state = WatchState(service: service)
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { !state.isLoading }
        var draft = WatchDraft()
        draft.name = "Saved watch"
        let saved = try await service.save(draft, editing: nil)
        try await waitUntil { state.watches.contains(saved) }
        state.select(saved.id)
        state.edit()
        state.draft?.name = "Keep my draft"
        draft.name = "Committed update"
        let updated = try await service.save(draft, editing: saved.id)
        try await waitUntil { state.selectedWatch == updated }
        #expect(state.draft?.name == "Keep my draft")
        state.searchText = "committed"
        #expect(state.filteredWatches == [updated])
        state.cancel()
        #expect(state.selectedWatch == updated)
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
        let state = WatchState(service: WatchService(coordinator: coordinator))
        state.create()
        state.draft?.name = "Unsaved"
        state.cancel()
        #expect(state.draft == nil)
        #expect(!state.hasUnsavedChanges)
        #expect(try await coordinator.read(WatchQueries.fetchAll).isEmpty)
        state.create()
        state.draft?.name = "Saved"
        #expect(await state.save())
        let saved = try #require(state.selectedWatch)
        state.edit()
        state.draft?.name = "Unsaved edit"
        state.cancel()
        #expect(state.selectedWatch == saved)
        #expect(try await coordinator.read(WatchQueries.fetchAll) == [saved])
        try await coordinator.close()
    }

    @Test
    func stayDiscardAndSaveProtectPendingNavigation() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let state = WatchState(service: WatchService(coordinator: coordinator))
        var navigated = false
        state.create()
        state.draft?.name = "Draft watch"
        state.requestNavigation { navigated = true }
        #expect(state.showsUnsavedChanges)
        #expect(!navigated)
        state.stay()
        #expect(state.draft?.name == "Draft watch")
        #expect(!navigated)
        state.requestNavigation { navigated = true }
        await state.saveAndContinue()
        #expect(navigated)
        #expect(state.draft == nil)
        #expect(state.selectedWatch?.name == "Draft watch")
        #expect(!state.showsUnsavedChanges)
        state.edit()
        state.draft?.name = "Discarded edit"
        navigated = false
        state.requestNavigation { navigated = true }
        state.discardAndContinue()
        #expect(navigated)
        #expect(state.selectedWatch?.name == "Draft watch")
        #expect(try await coordinator.read(WatchQueries.fetchAll).first?.name == "Draft watch")
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
                    CREATE TRIGGER failWatchInsert BEFORE INSERT ON watch
                    BEGIN SELECT RAISE(ABORT, 'fixture disk failure'); END
                    """)
        }
        let state = WatchState(service: WatchService(coordinator: coordinator))
        state.create()
        state.draft?.name = "Keep this draft"
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
        #expect(try await coordinator.read(WatchQueries.fetchAll).isEmpty)
        try await coordinator.mutate { db, _, _ in
            try db.execute(sql: "DROP TRIGGER failWatchInsert")
        }
        state.requestNavigation { closed = true }
        await state.saveAndContinue()
        #expect(closed)
        #expect(state.selectedWatch?.name == "Keep this draft")
        #expect(state.saveError == nil)
        try await coordinator.close()
    }

    @Test
    func validationErrorsKeepTheDraftAndClearAfterCorrection() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let state = WatchState(service: WatchService(coordinator: coordinator))
        state.create()
        state.draft?.lugWidth = "-18"
        #expect(!(await state.save()))
        #expect(state.fieldErrors[.name] != nil)
        #expect(state.fieldErrors[.lugWidth] != nil)
        #expect(state.draft?.lugWidth == "-18")
        state.draft?.name = "Watch"
        state.draft?.lugWidth = "18"
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
        let state = WatchState(service: WatchService(coordinator: coordinator))
        state.create()
        state.draft?.name = "One watch"
        let saving = Task { await state.save() }
        try await waitUntil { state.isSaving }
        #expect(!(await state.save()))
        var navigated = false
        state.requestNavigation { navigated = true }
        state.cancel()
        #expect(!navigated)
        #expect(state.draft?.name == "One watch")
        gate.signal()
        try await blocker.value
        #expect(await saving.value)
        #expect(try await coordinator.read(WatchQueries.fetchAll).count == 1)
        try await coordinator.close()
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
