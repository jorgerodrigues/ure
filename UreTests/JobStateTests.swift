import Foundation
import GRDB
import Testing

@testable import Ure

struct JobStateTests {
    @Test(.timeLimit(.minutes(1)))
    func cancelAndValidationKeepNewJobsOutOfHistoryUntilSaved() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let (state, observation) = try await makeState(coordinator)
        defer { observation.cancel() }
        state.start(for: watch.id)
        state.draft?.title = "Cancelled intake"
        state.cancel()
        #expect(state.draft == nil)
        #expect(state.history(for: watch.id).isEmpty)
        #expect(try await coordinator.read(JobQueries.fetchAll).isEmpty)
        state.start(for: watch.id)
        #expect(!(await state.save()))
        #expect(state.fieldErrors[.title] != nil)
        #expect(state.draft != nil)
        state.draft?.title = "Planned repair"
        #expect(await state.save())
        #expect(state.selectedJob?.stage == .planned)
        #expect(state.fieldErrors.isEmpty)
        state.close()
        state.start(for: watch.id)
        #expect(state.draft == nil)
        #expect(state.selectedJob?.title == "Planned repair")
        #expect(try await coordinator.read(JobQueries.fetchAll).count == 1)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func observedEditsRefreshDetailAndHistoryWithoutReplacingAnOpenDraft() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let (state, observation) = try await makeState(coordinator)
        defer { observation.cancel() }
        state.start(for: watch.id)
        state.draft?.title = "Saved job"
        #expect(await state.save())
        let saved = try #require(state.selectedJob)
        state.edit()
        state.draft?.title = "Keep my draft"
        var draft = JobDraft(job: saved)
        draft.title = "Committed edit"
        let updated = try await JobService(coordinator: coordinator).save(
            draft, for: watch.id, editing: saved.id)
        try await waitUntil { state.selectedJob == updated }
        #expect(state.draft?.title == "Keep my draft")
        #expect(state.history(for: watch.id) == [updated])
        #expect(state.history(for: UUID()).isEmpty)
        state.cancel()
        #expect(state.selectedJob == updated)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func sharedGuardProtectsJobNavigationAndSaveFailureCancelsClosure() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let (state, observation) = try await makeState(coordinator)
        defer { observation.cancel() }
        let editing = WorkshopEditing(
            watches: WatchState(service: WatchService(coordinator: coordinator)),
            calibers: CaliberState(service: CaliberService(coordinator: coordinator)), jobs: state,
            notes: NoteState(service: NoteService(coordinator: coordinator)),
            references: ReferenceState(service: ReferenceService(coordinator: coordinator)),
            photos: PhotoState(service: PhotoService(coordinator: coordinator)))
        state.start(for: watch.id)
        state.draft?.title = "Keep this intake"
        var navigated = false
        editing.requestNavigation { navigated = true }
        #expect(editing.unsavedChangesTitle == "Save changes to this job?")
        #expect(editing.showsUnsavedChanges)
        editing.stay()
        #expect(!navigated)
        #expect(state.draft?.title == "Keep this intake")
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql:
                    "CREATE TRIGGER failJobInsert BEFORE INSERT ON job BEGIN SELECT RAISE(ABORT, 'fixture disk failure'); END"
            )
        }
        var cancelled = false
        editing.requestNavigation({ navigated = true }, onCancel: { cancelled = true })
        await editing.saveAndContinue()
        #expect(!navigated)
        #expect(cancelled)
        #expect(state.draft?.title == "Keep this intake")
        #expect(state.saveError != nil)
        #expect(!editing.isNavigationPending)
        #expect(try await coordinator.read(JobQueries.fetchAll).isEmpty)
        try await coordinator.mutate { db, _, _ in try db.execute(sql: "DROP TRIGGER failJobInsert")
        }
        editing.requestNavigation { navigated = true }
        await editing.saveAndContinue()
        #expect(navigated)
        #expect(state.selectedJob?.title == "Keep this intake")
        state.edit()
        state.draft?.title = "Discarded edit"
        editing.requestNavigation(state.close)
        editing.discardAndContinue()
        #expect(state.selectedID == nil)
        #expect(state.draft == nil)
        #expect(state.jobs.first?.title == "Keep this intake")
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func staleCreationKeepsTheDraftAndOffersTheExistingJob() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let (state, observation) = try await makeState(coordinator)
        defer { observation.cancel() }
        state.start(for: watch.id)
        state.draft?.title = "Pending intake"
        var external = JobDraft()
        external.title = "Existing job"
        let saved = try await JobService(coordinator: coordinator).save(
            external, for: watch.id, editing: nil)
        #expect(!(await state.save()))
        #expect(state.conflictingJobID == saved.id)
        #expect(state.draft?.title == "Pending intake")
        try await waitUntil { state.jobs.contains(saved) }
        state.openConflictingJob()
        #expect(state.showsUnsavedChanges)
        state.discardAndContinue()
        #expect(state.selectedJob == saved)
        #expect(state.draft == nil)
        #expect(try await coordinator.read(JobQueries.fetchAll) == [saved])
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingSaveBlocksRepeatedSaveAndNavigation() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let (state, observation) = try await makeState(coordinator)
        defer { observation.cancel() }
        state.start(for: watch.id)
        state.draft?.title = "One job"
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
        #expect(state.draft?.title == "One job")
        gate.signal()
        try await blocker.value
        #expect(await saving.value)
        #expect(try await coordinator.read(JobQueries.fetchAll).count == 1)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func loadingFailureCanBeRetriedAndPreventsStartingFromMissingHistory() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        let state = JobState(service: JobService(coordinator: coordinator))
        await state.observe()
        #expect(state.loadError != nil)
        state.start(for: UUID())
        #expect(state.draft == nil)
        _ = try await coordinator.open()
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { !state.isLoading && state.loadError == nil }
        #expect(state.jobs.isEmpty)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func actionDraftsKeepValidationAndUseTheSharedNavigationGuard() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let (state, observation) = try await makeState(coordinator)
        defer { observation.cancel() }
        state.start(for: watch.id)
        state.draft?.title = "Repair"
        #expect(await state.save())
        let job = try #require(state.selectedJob)
        state.beginAction(.transition, watch: watch)
        state.actionDraft?.transition.stage = .waiting
        #expect(!(await state.save()))
        #expect(state.fieldErrors[.waitingReason] != nil)
        #expect(state.actionDraft?.transition.stage == .waiting)
        #expect(state.selectedJob == job)
        state.actionDraft?.transition.waitingReason = "Await inspection"
        var navigated = false
        state.requestNavigation { navigated = true }
        #expect(state.showsUnsavedChanges)
        state.stay()
        #expect(!navigated)
        state.requestNavigation { navigated = true }
        await state.saveAndContinue()
        #expect(navigated)
        #expect(state.selectedJob?.stage == .waiting)
        #expect(state.actionDraft == nil)
        state.beginAction(.condition, watch: watch)
        state.actionDraft?.condition.condition = .disassembled
        state.requestNavigation(state.close)
        state.discardAndContinue()
        #expect(state.selectedID == nil)
        #expect(try await coordinator.read(WatchQueries.fetchAll) == [watch])
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [JobAction.transition, .condition, .reopen])
    func pendingActionsRejectRepeatedSavesAndNavigation(action: JobAction) async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let (state, observation) = try await makeState(coordinator)
        defer { observation.cancel() }
        state.start(for: watch.id)
        state.draft?.title = "Repair"
        #expect(await state.save())
        let job = try #require(state.selectedJob)
        if action == .reopen {
            var completion = JobTransitionDraft(stage: .completed)
            completion.outcome = "Serviced"
            let closed = try await JobService(coordinator: coordinator).transition(
                job.id, using: completion)
            try await waitUntil { state.selectedJob == closed }
            state.edit()
            state.beginAction(.condition, watch: watch)
            #expect(!state.isEditing)
        }
        state.beginAction(action, watch: watch)
        if action == .transition { state.actionDraft?.transition.stage = .ready }
        if action == .condition { state.actionDraft?.condition.condition = .running }
        let before = try await coordinator.read(ActivityQueries.fetchAll)
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
        #expect(state.actionDraft != nil)
        gate.signal()
        try await blocker.value
        #expect(await saving.value)
        #expect(state.actionDraft == nil)
        #expect(try await coordinator.read(ActivityQueries.fetchAll).count == before.count + 1)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func actionWriteFailureKeepsTheDraftAndSavedState() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let (state, observation) = try await makeState(coordinator)
        defer { observation.cancel() }
        state.start(for: watch.id)
        state.draft?.title = "Repair"
        #expect(await state.save())
        let job = try #require(state.selectedJob)
        state.beginAction(.condition, watch: watch)
        state.actionDraft?.condition.condition = .running
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql:
                    "CREATE TRIGGER failEvent BEFORE INSERT ON activityEvent BEGIN SELECT RAISE(ABORT, 'fixture failure'); END"
            )
        }
        #expect(!(await state.save()))
        #expect(state.actionDraft?.condition.condition == .running)
        #expect(state.saveError != nil)
        #expect(state.selectedJob == job)
        #expect(try await coordinator.read(WatchQueries.fetchAll) == [watch])
        #expect(try await coordinator.read(ActivityQueries.fetchAll).isEmpty)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    private func makeState(_ coordinator: LibraryCoordinator) async throws -> (
        JobState, Task<Void, Never>
    ) {
        let state = JobState(service: JobService(coordinator: coordinator))
        let observation = Task { await state.observe() }
        do {
            try await waitUntil { !state.isLoading }
        } catch {
            observation.cancel()
            throw error
        }
        return (state, observation)
    }

    private func makeWatch(_ coordinator: LibraryCoordinator) async throws -> WatchRecord {
        var draft = WatchDraft()
        draft.name = "Inherited watch"
        return try await WatchService(coordinator: coordinator).save(draft, editing: nil)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw JobObservationTimeout()
    }
}

nonisolated private struct JobObservationTimeout: Error {}
