import Foundation
import GRDB
import Testing

@testable import Ure

struct NoteStateTests {
    @Test(.timeLimit(.minutes(1)))
    func creationValidationCancellationAndScopeFiltering() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owners = try await NoteFixture.owners(coordinator)
        let (state, observation) = try await makeState(coordinator)
        defer { observation.cancel() }
        state.create(for: owners[0])
        state.draft?.title = "Discarded note"
        state.cancel()
        #expect(state.draft == nil)
        #expect(state.owner == nil)
        #expect(try await coordinator.read(NoteQueries.fetchAll).isEmpty)
        state.create(for: owners[0])
        #expect(!(await state.save()))
        #expect(state.fieldErrors[.title] != nil)
        #expect(state.draft != nil)
        state.draft?.title = "Watch finding"
        #expect(await state.save())
        let first = try #require(state.selectedNote)
        #expect(state.records(for: owners[0]) == [first])
        #expect(state.records(for: owners[1]).isEmpty)
        #expect(state.records(for: owners[2]).isEmpty)
        state.edit()
        state.draft?.body = "Discarded correction"
        state.cancel()
        #expect(state.selectedNote == first)
        state.open(first, for: owners[2])
        #expect(state.owner == owners[0])
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func observedChangesRefreshSelectedNoteWithoutReplacingDraft() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owner = try #require(try await NoteFixture.owners(coordinator).first)
        let (state, observation) = try await makeState(coordinator)
        defer { observation.cancel() }
        state.create(for: owner)
        state.draft?.title = "Saved note"
        #expect(await state.save())
        let saved = try #require(state.selectedNote)
        state.edit()
        state.draft?.body = "Keep this draft"
        var edit = NoteDraft(note: saved)
        edit.body = "Committed correction"
        let updated = try await NoteService(coordinator: coordinator).save(
            edit, for: owner, editing: saved.id)
        try await waitUntil { state.selectedNote == updated }
        #expect(state.draft?.body == "Keep this draft")
        #expect(state.draft?.occurredAt == saved.occurredAt)
        state.cancel()
        #expect(state.selectedNote == updated)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func sharedGuardKeepsFailedDraftAndSupportsStaySaveDiscard() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owner = try #require(try await NoteFixture.owners(coordinator).first)
        let (state, observation) = try await makeState(coordinator)
        defer { observation.cancel() }
        let editing = WorkshopEditing(
            watches: WatchState(service: WatchService(coordinator: coordinator)),
            calibers: CaliberState(service: CaliberService(coordinator: coordinator)),
            jobs: JobState(service: JobService(coordinator: coordinator)), notes: state,
            references: ReferenceState(service: ReferenceService(coordinator: coordinator)),
            photos: PhotoState(service: PhotoService(coordinator: coordinator)))
        state.create(for: owner)
        state.draft?.title = "Keep this note"
        let occurred = state.draft?.occurredAt
        var navigated = false
        editing.requestNavigation { navigated = true }
        #expect(editing.unsavedChangesTitle == "Save changes to this note?")
        #expect(editing.showsUnsavedChanges)
        editing.stay()
        #expect(!navigated)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql:
                    "CREATE TRIGGER failNote BEFORE INSERT ON note BEGIN SELECT RAISE(ABORT, 'fixture disk failure'); END"
            )
        }
        var cancelled = false
        editing.requestNavigation({ navigated = true }, onCancel: { cancelled = true })
        await editing.saveAndContinue()
        #expect(!navigated)
        #expect(cancelled)
        #expect(state.draft?.title == "Keep this note")
        #expect(state.draft?.occurredAt == occurred)
        #expect(state.saveError != nil)
        #expect(!editing.isNavigationPending)
        #expect(try await coordinator.read(NoteQueries.fetchAll).isEmpty)
        try await coordinator.mutate { db, _, _ in try db.execute(sql: "DROP TRIGGER failNote") }
        editing.requestNavigation { navigated = true }
        await editing.saveAndContinue()
        #expect(navigated)
        #expect(state.selectedNote?.title == "Keep this note")
        state.edit()
        state.draft?.title = "Discard this change"
        editing.requestNavigation(state.close)
        editing.discardAndContinue()
        #expect(state.owner == nil)
        #expect(state.draft == nil)
        #expect(state.notes.first?.title == "Keep this note")
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingSaveBlocksDuplicateSaveCancelAndNavigation() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owner = try #require(try await NoteFixture.owners(coordinator).first)
        let (state, observation) = try await makeState(coordinator)
        defer { observation.cancel() }
        state.create(for: owner)
        state.draft?.title = "One note"
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
        let saving = Task { await state.save() }
        try await waitUntil { state.isSaving }
        #expect(!(await state.save()))
        var navigated = false
        state.requestNavigation { navigated = true }
        state.cancel()
        #expect(!navigated)
        #expect(state.draft?.title == "One note")
        gate.signal()
        try await blocker.value
        #expect(await saving.value)
        #expect(try await coordinator.read(NoteQueries.fetchAll).count == 1)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func closedJobDisablesWritesAndStaleEditorKeepsRejectedDraft() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owners = try await NoteFixture.owners(coordinator)
        let owner = owners[1]
        guard case .job(let jobID) = owner else { throw NoteFixtureError() }
        let (state, observation) = try await makeState(coordinator)
        defer { observation.cancel() }
        let jobs = JobState(service: JobService(coordinator: coordinator))
        let jobObservation = Task { await jobs.observe() }
        defer { jobObservation.cancel() }
        try await waitUntil { !jobs.isLoading }
        #expect(state.canWrite(owner, jobs: jobs))
        state.create(for: owner)
        state.draft?.title = "Job finding"
        #expect(await state.save())
        let saved = try #require(state.selectedNote)
        state.edit()
        state.draft?.body = "Pending correction"
        var closure = JobTransitionDraft(stage: .completed)
        closure.outcome = "Serviced"
        let closed = try await JobService(coordinator: coordinator).transition(
            jobID, using: closure)
        try await waitUntil { jobs.jobs.contains(closed) }
        #expect(!state.canWrite(owner, jobs: jobs))
        #expect(state.canWrite(owners[0], jobs: jobs))
        #expect(!(await state.save()))
        #expect(state.draft?.body == "Pending correction")
        #expect(state.selectedNote == saved)
        #expect(state.saveError != nil)
        _ = try await JobService(coordinator: coordinator).reopen(
            jobID, using: JobTransitionDraft(stage: .planned))
        #expect(await state.save())
        #expect(state.selectedNote?.body == "Pending correction")
        observation.cancel()
        jobObservation.cancel()
        await observation.value
        await jobObservation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func loadFailureCanRetryAndPreventsStartingFromAnUnavailableList() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        let state = NoteState(service: NoteService(coordinator: coordinator))
        await state.observe()
        #expect(state.loadError != nil)
        state.create(for: .watch(UUID()))
        #expect(state.draft == nil)
        _ = try await coordinator.open()
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { !state.isLoading && state.loadError == nil }
        #expect(state.notes.isEmpty)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    private func makeState(_ coordinator: LibraryCoordinator) async throws -> (
        NoteState, Task<Void, Never>
    ) {
        let state = NoteState(service: NoteService(coordinator: coordinator))
        let observation = Task { await state.observe() }
        do {
            try await waitUntil { !state.isLoading }
        } catch {
            observation.cancel()
            throw error
        }
        return (state, observation)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NoteObservationTimeout()
    }
}

nonisolated private struct NoteObservationTimeout: Error {}
