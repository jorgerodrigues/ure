import Foundation
import GRDB
import Synchronization
import Testing

@testable import Ure

struct JobStateTests {
    @Test(.timeLimit(.minutes(1)))
    func startingAJobSelectsItWithTheCursorInItsTitle() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let (state, observation) = try await makeState(coordinator)
        defer { observation.cancel() }
        #expect(await state.start(for: watch.id).didSave)
        let job = try #require(state.selectedJob)
        #expect(job.title == "New Job" && job.stage == .inProgress)
        #expect(state.watchID == watch.id && state.titleToFocus == job.id)
        #expect(state.facts(for: job.id)?.title.text == "New Job")
        state.titleFocused()
        #expect(state.titleToFocus == nil)
        state.close()
        #expect(state.selectedJob == nil && state.watchID == nil)
        #expect(state.start(for: watch.id) == nil)
        #expect(state.selectedJob == job && state.titleToFocus == nil)
        try await waitUntil { state.jobs == [job] }
        #expect(try await coordinator.read(JobQueries.fetchAll) == [job])

        let archived = try await makeWatch(coordinator)
        _ = try await ArchiveService(coordinator: coordinator).setWatch(archived.id, archived: true)
        state.close()
        // An archived watch takes no job, so the start stops the queue with its reason.
        #expect(state.start(for: archived.id) != nil)
        #expect(await state.queue.waitUntilStopped())
        #expect(state.queue.failure != nil && state.selectedJob == nil)
        state.queue.discardUnsaved()
        #expect(state.queue.isIdle)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func theTitleProblemAndWaitingTextSaveWithoutAButton() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let job = try await JobService(coordinator: coordinator).start(for: watch.id)
        let (state, observation) = try await makeState(coordinator, pause: PauseGate().pause)
        defer { observation.cancel() }
        try await waitUntil { state.jobs == [job] }
        state.open(job)
        let facts = try #require(state.facts(for: job.id))
        facts.title.beginEditing()
        facts.title.change(to: "Full service", undoManager: nil)
        #expect(state.queue.hasUnsavedTyping)
        facts.title.endEditing()
        try await waitUntil { !facts.title.hasUnsavedChanges }
        let problem = "Loses about two minutes a day.\nThe crown feels gritty."
        facts.problem.beginEditing()
        facts.problem.change(to: problem, undoManager: nil)
        facts.problem.endEditing()
        try await waitUntil { !facts.problem.hasUnsavedChanges }
        var saved = try #require(try await coordinator.read(JobQueries.fetchAll).first)
        #expect(saved.title == "Full service" && saved.problem == problem)

        #expect(await state.setStage(.waiting).didSave)
        #expect(state.waitingToFocus == job.id && state.selectedJob?.stage == .waiting)
        state.waitingFocused()
        facts.waitingFor.beginEditing()
        facts.waitingFor.change(to: "a mainspring from Cousins", undoManager: nil)
        facts.waitingFor.endEditing()
        try await waitUntil { !facts.waitingFor.hasUnsavedChanges }
        saved = try #require(try await coordinator.read(JobQueries.fetchAll).first)
        #expect(saved.waitingFor == "a mainspring from Cousins")

        facts.title.beginEditing()
        facts.title.change(to: " ", undoManager: nil)
        facts.title.endEditing()
        #expect(facts.title.problem == "Enter a title.")
        #expect(try await coordinator.read(JobQueries.fetchAll).first?.title == "Full service")
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func changingTheStateSavesRecordsTheDateAndUndoPutsItBack() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let opened = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = Mutex(opened)
        let coordinator = fixture.coordinator(
            dependencies: LibraryDependencies(now: { clock.withLock { $0 } }))
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let job = try await JobService(coordinator: coordinator).start(for: watch.id)
        let (state, observation) = try await makeState(coordinator)
        defer { observation.cancel() }
        try await waitUntil { state.jobs == [job] }
        state.open(job)
        let undo = UndoManager()
        undo.groupsByEvent = false

        let doneDay = opened.addingTimeInterval(86_400)
        clock.withLock { $0 = doneDay }
        try await change(state, to: .done, undo: undo)
        #expect(try await stored(job.id, coordinator)?.doneAt == doneDay)
        #expect(state.selectedJob?.stage == .done)
        #expect(undo.undoMenuItemTitle == "Undo Change State")

        clock.withLock { $0 = doneDay.addingTimeInterval(86_400) }
        undo.undo()
        await state.queue.waitUntilIdle()
        var saved = try #require(try await stored(job.id, coordinator))
        #expect(saved.stage == .inProgress && saved.doneAt == nil && saved.createdAt == opened)
        #expect(undo.redoMenuItemTitle == "Redo Change State")
        undo.redo()
        await state.queue.waitUntilIdle()
        saved = try #require(try await stored(job.id, coordinator))
        #expect(saved.stage == .done && saved.doneAt == doneDay)

        try await change(state, to: .waiting, undo: undo)
        let facts = try #require(state.facts(for: job.id))
        facts.waitingFor.beginEditing()
        facts.waitingFor.change(to: "the owner's answer", undoManager: nil)
        try await change(state, to: .inProgress, undo: undo)
        saved = try #require(try await stored(job.id, coordinator))
        #expect(saved.stage == .inProgress && saved.waitingFor == nil && saved.doneAt == nil)
        undo.undo()
        await state.queue.waitUntilIdle()
        saved = try #require(try await stored(job.id, coordinator))
        #expect(saved.stage == .waiting && saved.waitingFor == "the owner's answer")
        try await waitUntil { facts.waitingFor.text == "the owner's answer" }
        undo.undo()
        await state.queue.waitUntilIdle()
        saved = try #require(try await stored(job.id, coordinator))
        #expect(saved.stage == .done && saved.doneAt == doneDay && saved.waitingFor == nil)
        state.queue.discardUndo()
        #expect(!undo.canUndo)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func undoingAStateAndTheWaitingTextBeforeItAtOncePutsBackBothInOrder() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let job = try await JobService(coordinator: coordinator).start(for: watch.id)
        let (state, observation) = try await makeState(coordinator, pause: PauseGate().pause)
        defer { observation.cancel() }
        try await waitUntil { state.jobs == [job] }
        state.open(job)
        let undo = UndoManager()
        undo.groupsByEvent = false
        try await change(state, to: .waiting, undo: undo)
        let field = try #require(state.facts(for: job.id)?.waitingFor)
        for text in ["a crystal", "a crystal and a gasket"] {
            field.beginEditing()
            undo.beginUndoGrouping()
            field.change(to: text, undoManager: undo)
            undo.endUndoGrouping()
            field.endEditing()
            try await waitUntil { !field.hasUnsavedChanges }
        }
        try await change(state, to: .done, undo: undo)
        #expect(try await stored(job.id, coordinator)?.waitingFor == nil)

        // Both steps run before either save reaches the library.
        undo.undo()
        undo.undo()
        await state.queue.waitUntilIdle()
        try await waitUntil { !field.hasUnsavedChanges && !state.isSaving }
        var saved = try #require(try await stored(job.id, coordinator))
        #expect(saved.stage == .waiting && saved.waitingFor == "a crystal")
        #expect(state.refusal == nil)
        undo.redo()
        undo.redo()
        await state.queue.waitUntilIdle()
        try await waitUntil { !field.hasUnsavedChanges && !state.isSaving }
        saved = try #require(try await stored(job.id, coordinator))
        #expect(saved.stage == .done && saved.waitingFor == nil)
        #expect(state.refusal == nil)
        #expect(await state.setStage(.inProgress, undoManager: nil).didSave)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aStateChangeWaitsForTypingAndStopsAtATitleThatIsNotValid() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let job = try await JobService(coordinator: coordinator).start(for: watch.id)
        let (state, observation) = try await makeState(coordinator, pause: PauseGate().pause)
        defer { observation.cancel() }
        try await waitUntil { state.jobs == [job] }
        state.open(job)
        let facts = try #require(state.facts(for: job.id))
        facts.problem.beginEditing()
        facts.problem.change(to: "Stops overnight.", undoManager: nil)
        #expect(await state.setStage(.done).didSave)
        var saved = try #require(try await stored(job.id, coordinator))
        #expect(saved.stage == .done && saved.problem == "Stops overnight.")
        facts.problem.endEditing()

        facts.title.beginEditing()
        facts.title.change(to: "", undoManager: nil)
        facts.title.endEditing()
        #expect(await !state.setStage(.inProgress).didSave)
        #expect(state.refusal != nil && !state.isSaving)
        saved = try #require(try await stored(job.id, coordinator))
        #expect(saved.stage == .done && saved.title == "New Job")
        facts.title.beginEditing()
        facts.title.change(to: "Crystal", undoManager: nil)
        #expect(await state.setStage(.inProgress).didSave)
        saved = try #require(try await stored(job.id, coordinator))
        #expect(saved.stage == .inProgress && saved.title == "Crystal" && state.refusal == nil)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func leavingDoneWhileTheWatchHasAnotherOpenJobSaysSoAndKeepsTheJob() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await makeWatch(coordinator)
        let service = JobService(coordinator: coordinator)
        let first = try await service.start(for: watch.id, title: "First repair")
        let done = try await service.setStage(first.id, to: .done).job
        let second = try await service.start(for: watch.id, title: "Second repair")
        let (state, observation) = try await makeState(coordinator)
        defer { observation.cancel() }
        try await waitUntil { state.jobs.count == 2 }
        state.open(done)
        let undo = UndoManager()
        #expect(await !state.setStage(.inProgress, undoManager: undo).didSave)
        #expect(
            state.refusal
                == "This watch already has an open job. Open that job to continue its repair.")
        #expect(!undo.canUndo && state.selectedJob == done)
        #expect(state.openJob(for: watch.id) == second)
        #expect(try await stored(first.id, coordinator) == done)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func loadingFailureCanBeRetriedAndStartsNoJob() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        let state = JobState(queue: EditQueue(coordinator: coordinator))
        await state.observe()
        #expect(!state.isLoading && state.loadError != nil)
        #expect(await !state.start(for: UUID()).didSave)
        _ = try await coordinator.open()
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { !state.isLoading && state.loadError == nil }
        #expect(state.jobs.isEmpty)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    // The test host groups Undo by hand. A state change registers its Undo when it is asked for.
    private func change(_ state: JobState, to stage: JobStage, undo: UndoManager) async throws {
        undo.beginUndoGrouping()
        let changed = state.setStage(stage, undoManager: undo)
        undo.endUndoGrouping()
        #expect(await changed.didSave)
        try await waitUntil { state.selectedJob?.stage == stage }
    }

    private func stored(_ id: UUID, _ coordinator: LibraryCoordinator) async throws -> JobRecord? {
        try await coordinator.read { try JobQueries.fetch(id, in: $0) }
    }

    private func makeState(
        _ coordinator: LibraryCoordinator,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> (JobState, Task<Void, Never>) {
        let state = JobState(queue: EditQueue(coordinator: coordinator), pause: pause)
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
        try await WatchService(coordinator: coordinator).make("Inherited watch")
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
