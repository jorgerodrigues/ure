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
        #expect(await state.start(for: watch.id))
        let job = try #require(state.selectedJob)
        #expect(job.title == "New Job" && job.stage == .inProgress)
        #expect(state.watchID == watch.id && state.titleToFocus == job.id)
        #expect(state.facts(for: job.id)?.title.text == "New Job")
        state.titleFocused()
        #expect(state.titleToFocus == nil)
        state.close()
        #expect(state.selectedJob == nil && state.watchID == nil)
        #expect(await state.start(for: watch.id))
        #expect(state.selectedJob == job && state.titleToFocus == nil)
        try await waitUntil { state.jobs == [job] }
        #expect(try await coordinator.read(JobQueries.fetchAll) == [job])

        let archived = try await makeWatch(coordinator)
        _ = try await ArchiveService(coordinator: coordinator).setWatch(archived.id, archived: true)
        state.close()
        #expect(await !state.start(for: archived.id))
        #expect(state.saveError != nil && state.selectedJob == nil)
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
        #expect(state.hasUnsavedFacts)
        facts.title.endEditing()
        try await waitUntil { !facts.title.hasUnsavedChanges }
        let problem = "Loses about two minutes a day.\nThe crown feels gritty."
        facts.problem.beginEditing()
        facts.problem.change(to: problem, undoManager: nil)
        facts.problem.endEditing()
        try await waitUntil { !facts.problem.hasUnsavedChanges }
        var saved = try #require(try await coordinator.read(JobQueries.fetchAll).first)
        #expect(saved.title == "Full service" && saved.problem == problem)

        #expect(await state.setStage(.waiting))
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
        await state.waitForStageChanges()
        var saved = try #require(try await stored(job.id, coordinator))
        #expect(saved.stage == .inProgress && saved.doneAt == nil && saved.createdAt == opened)
        #expect(undo.redoMenuItemTitle == "Redo Change State")
        undo.redo()
        await state.waitForStageChanges()
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
        await state.waitForStageChanges()
        saved = try #require(try await stored(job.id, coordinator))
        #expect(saved.stage == .waiting && saved.waitingFor == "the owner's answer")
        try await waitUntil { facts.waitingFor.text == "the owner's answer" }
        undo.undo()
        await state.waitForStageChanges()
        saved = try #require(try await stored(job.id, coordinator))
        #expect(saved.stage == .done && saved.doneAt == doneDay && saved.waitingFor == nil)
        state.discardUndo()
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
        await state.waitForStageChanges()
        try await waitUntil { !field.hasUnsavedChanges && !state.isSaving }
        var saved = try #require(try await stored(job.id, coordinator))
        #expect(saved.stage == .waiting && saved.waitingFor == "a crystal")
        #expect(field.saveError == nil && state.saveError == nil)
        undo.redo()
        undo.redo()
        await state.waitForStageChanges()
        try await waitUntil { !field.hasUnsavedChanges && !state.isSaving }
        saved = try #require(try await stored(job.id, coordinator))
        #expect(saved.stage == .done && saved.waitingFor == nil)
        #expect(field.saveError == nil && state.saveError == nil)
        #expect(await state.setStage(.inProgress, undoManager: nil))
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
        #expect(await state.setStage(.done))
        var saved = try #require(try await stored(job.id, coordinator))
        #expect(saved.stage == .done && saved.problem == "Stops overnight.")
        facts.problem.endEditing()

        facts.title.beginEditing()
        facts.title.change(to: "", undoManager: nil)
        facts.title.endEditing()
        #expect(await !state.setStage(.inProgress))
        #expect(state.saveError != nil && !state.isSaving)
        saved = try #require(try await stored(job.id, coordinator))
        #expect(saved.stage == .done && saved.title == "New Job")
        facts.title.beginEditing()
        facts.title.change(to: "Crystal", undoManager: nil)
        #expect(await state.setStage(.inProgress))
        saved = try #require(try await stored(job.id, coordinator))
        #expect(saved.stage == .inProgress && saved.title == "Crystal" && state.saveError == nil)
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
        #expect(await !state.setStage(.inProgress, undoManager: undo))
        #expect(
            state.saveError
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
        let state = JobState(service: JobService(coordinator: coordinator))
        await state.observe()
        #expect(!state.isLoading && state.loadError != nil)
        #expect(await !state.start(for: UUID()))
        _ = try await coordinator.open()
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { !state.isLoading && state.loadError == nil }
        #expect(state.jobs.isEmpty)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    // The test host groups Undo by hand, and a state change registers its Undo after it saves,
    // so the group stays open across the change.
    private func change(_ state: JobState, to stage: JobStage, undo: UndoManager) async throws {
        undo.beginUndoGrouping()
        let changed = await state.setStage(stage, undoManager: undo)
        undo.endUndoGrouping()
        #expect(changed)
        try await waitUntil { state.selectedJob?.stage == stage }
    }

    private func stored(_ id: UUID, _ coordinator: LibraryCoordinator) async throws -> JobRecord? {
        try await coordinator.read { try JobQueries.fetch(id, in: $0) }
    }

    private func makeState(
        _ coordinator: LibraryCoordinator,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> (JobState, Task<Void, Never>) {
        let state = JobState(service: JobService(coordinator: coordinator), pause: pause)
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
