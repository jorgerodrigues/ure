import Foundation
import GRDB
import Testing

@testable import Ure

struct JobTaskStateTests {
    @Test(.timeLimit(.minutes(1)))
    func cancelledInvalidAndSavedDraftsStayInTheirJob() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let other = try await JobTaskFixture.job(coordinator)
        let (state, jobs, observations) = try await makeState(coordinator)
        defer { observations.forEach { $0.cancel() } }
        state.create(for: job.id, jobs: jobs)
        state.draft?.title = "Discard this"
        state.cancel()
        #expect(state.draft == nil && state.jobID == nil)
        #expect(try await coordinator.read(JobTaskQueries.fetchAll).isEmpty)
        state.create(for: job.id, jobs: jobs)
        #expect(!(await state.save()))
        #expect(state.fieldErrors[.title] != nil)
        state.draft?.title = "Inspect escapement"
        state.draft?.status = .waiting
        #expect(!(await state.save()))
        #expect(state.fieldErrors[.waitingReason] != nil)
        state.draft?.waitingReason = "Need a technical sheet"
        #expect(await state.save())
        let saved = try #require(state.selectedTask)
        #expect(state.records(for: job.id) == [saved])
        #expect(state.records(for: other.id).isEmpty)
        state.open(saved, for: other.id)
        #expect(state.jobID == job.id)
        state.edit(jobs: jobs)
        state.draft?.title = "Unsaved correction"
        state.cancel()
        #expect(state.selectedTask == saved)
        for observation in observations { observation.cancel(); await observation.value }
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func sharedGuardSupportsStaySaveDiscardAndKeepsFailedWrites() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let (state, jobs, observations) = try await makeState(coordinator)
        defer { observations.forEach { $0.cancel() } }
        let editing = makeEditing(coordinator, tasks: state, jobs: jobs)
        state.create(for: job.id, jobs: jobs)
        state.draft?.title = "Keep this task"
        state.draft?.status = .done
        var navigated = false
        editing.requestNavigation { navigated = true }
        #expect(editing.unsavedChangesTitle == "Save changes to this task?")
        #expect(editing.hasUnsavedChanges && editing.showsUnsavedChanges)
        editing.stay()
        #expect(!navigated)
        try await JobTaskFixture.failEvents(coordinator)
        var cancelled = false
        editing.requestNavigation({ navigated = true }, onCancel: { cancelled = true })
        await editing.saveAndContinue()
        #expect(!navigated && cancelled)
        #expect(state.draft?.title == "Keep this task" && state.draft?.status == .done)
        #expect(state.saveError != nil)
        #expect(!editing.isNavigationPending)
        #expect(try await coordinator.read(JobTaskQueries.fetchAll).isEmpty)
        #expect(try await coordinator.read(ActivityQueries.fetchAll).isEmpty)
        try await coordinator.mutate { db, _, _ in try db.execute(sql: "DROP TRIGGER failTaskEvent")
        }
        editing.requestNavigation { navigated = true }
        await editing.saveAndContinue()
        #expect(navigated && !editing.hasUnsavedChanges)
        #expect(state.selectedTask?.title == "Keep this task")
        #expect(try await coordinator.read(JobTaskQueries.fetchAll).count == 1)
        #expect(try await coordinator.read(ActivityQueries.fetchAll).count == 1)
        state.edit(jobs: jobs)
        state.draft?.title = "Discard this correction"
        editing.requestNavigation(state.close)
        editing.discardAndContinue()
        #expect(state.jobID == nil && state.draft == nil)
        #expect(state.tasks.first?.title == "Keep this task")
        for observation in observations { observation.cancel(); await observation.value }
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingSaveBlocksDuplicatesAndAllNavigation() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let (state, jobs, observations) = try await makeState(coordinator)
        defer { observations.forEach { $0.cancel() } }
        let editing = makeEditing(coordinator, tasks: state, jobs: jobs)
        state.create(for: job.id, jobs: jobs)
        state.draft?.title = "One task"
        state.draft?.status = .done
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
        #expect(editing.isSaving)
        #expect(!state.canSave(jobs: jobs))
        #expect(!(await state.save()))
        var navigated = false
        editing.requestNavigation { navigated = true }
        state.cancel()
        #expect(!navigated && state.draft?.title == "One task")
        gate.signal()
        try await blocker.value
        #expect(await saving.value)
        #expect(try await coordinator.read(JobTaskQueries.fetchAll).count == 1)
        #expect(try await coordinator.read(ActivityQueries.fetchAll).count == 1)
        for observation in observations { observation.cancel(); await observation.value }
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func observedChangesRefreshReadStateAndRejectStaleClosedJobEditor() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let (state, jobs, observations) = try await makeState(coordinator)
        defer { observations.forEach { $0.cancel() } }
        state.create(for: job.id, jobs: jobs)
        state.draft?.title = "Inspect movement"
        #expect(await state.save())
        let saved = try #require(state.selectedTask)
        state.edit(jobs: jobs)
        state.draft?.detail = "Keep my draft"
        var external = JobTaskDraft(task: saved)
        external.status = .doing
        let updated = try await JobTaskService(coordinator: coordinator).save(
            external, for: job.id, editing: saved.id)
        try await waitUntil { state.selectedTask == updated }
        #expect(state.draft?.detail == "Keep my draft" && state.draft?.status == .toDo)
        var closure = JobTransitionDraft(stage: .completed)
        closure.outcome = "Serviced"
        closure.unfinishedTasksReason = "Owner will handle inspection"
        let closed = try await JobService(coordinator: coordinator).transition(
            job.id, using: closure)
        try await waitUntil { jobs.jobs.contains(closed) }
        #expect(!state.canWrite(job.id, jobs: jobs) && !state.canSave(jobs: jobs))
        #expect(!(await state.save()))
        #expect(state.draft?.detail == "Keep my draft")
        #expect(state.saveError == JobError.closedJob.localizedDescription)
        #expect(try await coordinator.read(JobTaskQueries.fetchAll) == [updated])
        state.cancel()
        state.edit(jobs: jobs)
        state.create(for: job.id, jobs: jobs)
        #expect(state.draft == nil)
        #expect(state.selectedTask == updated)
        for observation in observations { observation.cancel(); await observation.value }
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func jobClosureSaveGateRequiresTaskSummaryAcrossCommandsAndNavigation() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        let tasks = JobTaskState(service: JobTaskService(coordinator: coordinator))
        let jobs = JobState(service: JobService(coordinator: coordinator))
        let editing = makeEditing(coordinator, tasks: tasks, jobs: jobs)
        #expect(tasks.isLoading)
        await tasks.observe()
        #expect(tasks.loadError != nil)
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let watch = try #require(try await coordinator.read(WatchQueries.fetchAll).first)
        let jobObservation = Task { await jobs.observe() }
        defer { jobObservation.cancel() }
        try await waitUntil { !jobs.isLoading }
        jobs.open(job)
        jobs.beginAction(.condition, watch: watch)
        #expect(editing.canSaveJob)
        jobs.cancel()
        jobs.beginAction(.transition, watch: watch)
        jobs.actionDraft?.transition.stage = .completed
        jobs.actionDraft?.transition.outcome = "Serviced"
        #expect(jobs.canSave && !editing.canSaveJob)
        editing.saveJobCommand()
        var navigated = false
        editing.requestNavigation { navigated = true }
        await editing.saveAndContinue()
        #expect(!navigated && !editing.isNavigationPending)
        #expect(jobs.actionDraft?.transition.stage == .completed)
        #expect(try await coordinator.read(JobQueries.fetchAll) == [job])
        #expect(try await coordinator.read(ActivityQueries.fetchAll).isEmpty)
        let taskObservation = Task { await tasks.observe() }
        defer { taskObservation.cancel() }
        try await waitUntil { !tasks.isLoading && tasks.loadError == nil }
        #expect(editing.canSaveJob)
        editing.requestNavigation { navigated = true }
        await editing.saveAndContinue()
        #expect(navigated)
        #expect(jobs.selectedJob?.stage == .completed)
        jobObservation.cancel()
        taskObservation.cancel()
        await jobObservation.value
        await taskObservation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func unopenedLibraryReportsLoadFailureAndAllowsRetry() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        let state = JobTaskState(service: JobTaskService(coordinator: coordinator))
        let jobs = JobState(service: JobService(coordinator: coordinator))
        await state.observe()
        #expect(state.loadError != nil && !state.isLoading)
        state.create(for: UUID(), jobs: jobs)
        #expect(state.draft == nil)
        _ = try await coordinator.open()
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { !state.isLoading && state.loadError == nil }
        #expect(state.tasks.isEmpty)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func savedMovesAddingAndReopeningRefreshOrderAndProgress() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = JobTaskService(coordinator: coordinator)
        let done = try await service.save(JobTaskFixture.draft(.done), for: job.id, editing: nil)
        let skipped = try await service.save(
            JobTaskFixture.draft(.skipped), for: job.id, editing: nil)
        let (state, jobs, observations) = try await makeState(coordinator)
        defer { observations.forEach { $0.cancel() } }
        #expect(state.progress(for: job.id).percentage == 100)
        #expect(state.progress(for: job.id).skippedCount == 1)
        #expect(!state.canMove(done.id, for: job.id, to: .up, jobs: jobs))
        #expect(!state.canMove(skipped.id, for: job.id, to: .down, jobs: jobs))
        #expect(await state.move(done.id, for: job.id, to: .down, jobs: jobs))
        #expect(state.records(for: job.id).map(\.id) == [skipped.id, done.id])
        #expect(state.progress(for: job.id).percentage == 100)
        state.create(for: job.id, jobs: jobs)
        state.draft?.title = "Final testing"
        #expect(!state.canReorder(job.id, jobs: jobs))
        #expect(await state.save())
        #expect(state.progress(for: job.id).percentage == 50)
        #expect(state.progress(for: job.id).countedCount == 2)
        state.open(done, for: job.id)
        state.edit(jobs: jobs)
        state.draft?.status = .doing
        #expect(await state.save())
        #expect(state.progress(for: job.id).percentage == 0)
        #expect(state.selectedTask?.position == 1)
        state.close()
        _ = try await service.move(done.id, for: job.id, to: .up)
        try await waitUntil { state.records(for: job.id).first?.id == done.id }
        for observation in observations { observation.cancel(); await observation.value }
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func failedMovesKeepVisibleOrderAndRejectClosedJobsWithStaleState() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = JobTaskService(coordinator: coordinator)
        let a = try await service.save(JobTaskFixture.draft(.done), for: job.id, editing: nil)
        let b = try await service.save(JobTaskFixture.draft(.skipped), for: job.id, editing: nil)
        let (state, jobs, observations) = try await makeState(coordinator)
        defer { observations.forEach { $0.cancel() } }
        state.open(a, for: job.id)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: """
                    CREATE TRIGGER failTaskOrder BEFORE UPDATE OF position ON jobTask
                    BEGIN SELECT RAISE(ABORT, 'fixture disk failure'); END
                    """)
        }
        #expect(!(await state.move(a.id, for: job.id, to: .down, jobs: jobs)))
        #expect(state.records(for: job.id) == [a, b])
        #expect(state.selectedTask == a && state.reorderError != nil)
        #expect(!state.isSaving && state.draft == nil)
        try await coordinator.mutate { db, _, _ in try db.execute(sql: "DROP TRIGGER failTaskOrder")
        }
        #expect(await state.move(a.id, for: job.id, to: .down, jobs: jobs))
        #expect(state.records(for: job.id).map(\.id) == [b.id, a.id])
        #expect(state.reorderError == nil && state.selectedTask?.id == a.id)
        for observation in observations { observation.cancel(); await observation.value }
        var closure = JobTransitionDraft(stage: .completed)
        closure.outcome = "Done"
        _ = try await JobService(coordinator: coordinator).transition(job.id, using: closure)
        let previous = state.records(for: job.id)
        #expect(state.canMove(a.id, for: job.id, to: .up, jobs: jobs))
        #expect(!(await state.move(a.id, for: job.id, to: .up, jobs: jobs)))
        #expect(state.records(for: job.id) == previous)
        #expect(state.reorderError?.contains(JobError.closedJob.localizedDescription) == true)
        let observation = Task { await jobs.observe() }
        defer { observation.cancel() }
        try await waitUntil { jobs.jobs.contains { $0.id == job.id && !$0.stage.isOpen } }
        #expect(!state.canReorder(job.id, jobs: jobs))
        #expect(!state.canMove(a.id, for: job.id, to: .up, jobs: jobs))
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingReorderBlocksDuplicateWritesAndSharedNavigation() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = JobTaskService(coordinator: coordinator)
        let a = try await service.save(JobTaskFixture.draft(.toDo), for: job.id, editing: nil)
        let b = try await service.save(JobTaskFixture.draft(.doing), for: job.id, editing: nil)
        let (state, jobs, observations) = try await makeState(coordinator)
        defer { observations.forEach { $0.cancel() } }
        let editing = makeEditing(coordinator, tasks: state, jobs: jobs)
        state.open(a, for: job.id)
        let started = AsyncStream<Void>.makeStream()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let blocker = Task {
            try await coordinator.mutate { _, _, _ in
                started.continuation.yield(()); gate.wait()
            }
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        let moving = Task { await state.move(a.id, for: job.id, to: .down, jobs: jobs) }
        try await waitUntil { state.isSaving }
        #expect(editing.isSaving && !state.canReorder(job.id, jobs: jobs))
        #expect(state.records(for: job.id) == [a, b])
        #expect(!(await state.move(a.id, for: job.id, to: .down, jobs: jobs)))
        var navigated = false
        editing.requestNavigation { navigated = true }
        state.edit(jobs: jobs)
        #expect(!navigated && state.draft == nil)
        gate.signal()
        try await blocker.value
        #expect(await moving.value)
        #expect(state.records(for: job.id).map(\.id) == [b.id, a.id])
        #expect(state.selectedTask?.id == a.id)
        for observation in observations { observation.cancel(); await observation.value }
        try await coordinator.close()
    }

    private func makeState(_ coordinator: LibraryCoordinator) async throws -> (
        JobTaskState, JobState, [Task<Void, Never>]
    ) {
        let state = JobTaskState(service: JobTaskService(coordinator: coordinator))
        let jobs = JobState(service: JobService(coordinator: coordinator))
        let observations = [Task { await state.observe() }, Task { await jobs.observe() }]
        do {
            try await waitUntil { !state.isLoading && !jobs.isLoading }
        } catch {
            observations.forEach { $0.cancel() }
            throw error
        }
        return (state, jobs, observations)
    }

    private func makeEditing(_ coordinator: LibraryCoordinator, tasks: JobTaskState, jobs: JobState)
        -> WorkshopEditing
    {
        WorkshopEditing(
            watches: WatchState(service: WatchService(coordinator: coordinator)),
            calibers: CaliberState(service: CaliberService(coordinator: coordinator)), jobs: jobs,
            notes: NoteState(service: NoteService(coordinator: coordinator)),
            references: ReferenceState(service: ReferenceService(coordinator: coordinator)),
            photos: PhotoState(service: PhotoService(coordinator: coordinator)),
            documents: DocumentState(service: DocumentService(coordinator: coordinator)),
            tasks: tasks)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw JobTaskObservationTimeout()
    }
}

nonisolated private struct JobTaskObservationTimeout: Error {}
