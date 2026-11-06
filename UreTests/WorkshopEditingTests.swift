import Foundation
import GRDB
import Testing

@testable import Ure

struct WorkshopEditingTests {
    @Test(.timeLimit(.minutes(1)))
    func partFactsSaveWhenLeavingOrQuittingWithoutAQuestion() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let parts = PartState(
            service: PartService(coordinator: coordinator), pause: PauseGate().pause)
        let jobs = JobState(service: JobService(coordinator: coordinator))
        let editing = MaterialEditingFixture.editing(coordinator, jobs: jobs, parts: parts)
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        try await waitUntil { !parts.isLoading }
        let part = try #require(await parts.add(named: "Mainspring", to: job.id))
        let facts = try #require(parts.facts(for: part.id))
        facts.name.beginEditing()
        facts.name.change(to: "Mainspring 1.10", undoManager: nil)
        #expect(editing.hasUnsavedFields)
        var navigated = false
        editing.requestNavigation { navigated = true }
        #expect(navigated)
        try await waitUntil { !facts.name.hasUnsavedChanges }
        facts.notes.beginEditing()
        facts.notes.change(to: "From Cousins, 3 November", undoManager: nil)
        #expect(await editing.saveAllFields())
        #expect(!editing.hasUnsavedFields)
        let saved = try #require(
            try await coordinator.read { try PartQueries.fetch(part.id, in: $0) })
        #expect(saved.name == "Mainspring 1.10" && saved.notes == "From Cousins, 3 November")
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func jobFactsSaveWhenLeavingOrQuittingWithoutTheDraftQuestion() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let jobs = JobState(service: JobService(coordinator: coordinator), pause: PauseGate().pause)
        let editing = MaterialEditingFixture.editing(coordinator, jobs: jobs)
        let observation = Task { await jobs.observe() }
        defer { observation.cancel() }
        try await waitUntil { jobs.jobs.count == 1 }
        let facts = try #require(jobs.facts(for: job.id))
        facts.title.beginEditing()
        facts.title.change(to: "Full service", undoManager: nil)
        #expect(editing.hasUnsavedFields)
        var navigated = false
        editing.requestNavigation { navigated = true }
        #expect(navigated)
        try await waitUntil { !facts.title.hasUnsavedChanges }
        facts.problem.beginEditing()
        facts.problem.change(to: "Stops overnight.", undoManager: nil)
        #expect(await editing.saveAllFields())
        #expect(!editing.hasUnsavedFields)
        let saved = try #require(
            try await coordinator.read { try JobQueries.fetch(job.id, in: $0) })
        #expect(saved.title == "Full service" && saved.problem == "Stops overnight.")
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aChecklistSavesWhenLeavingOrQuittingWithoutTheDraftQuestion() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let session = WorkshopSession(
            coordinator: coordinator, configuration: AppConfiguration(libraryRoot: fixture.root))
        let editing = session.editing
        let observation = Task { await session.checklist.observe() }
        defer { observation.cancel() }
        try await waitUntil { !session.checklist.isLoading }
        let editor = session.checklist.editor(for: job.id)
        let step = editor.addID
        editor.beginEditing(step)
        editor.change(step, to: "Clean all parts", undoManager: nil)
        #expect(editing.hasUnsavedFields)
        var navigated = false
        editing.requestNavigation { navigated = true }
        #expect(navigated)
        try await waitUntil { !editor.hasUnsavedChanges }
        editor.change(step, to: "Clean all parts twice", undoManager: nil)
        #expect(await editing.saveAllFields())
        #expect(!editing.hasUnsavedFields)
        #expect(
            try await coordinator.read(ChecklistQueries.fetchAll).map(\.text) == [
                "Clean all parts twice"
            ])
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func watchFactsSaveWhenLeavingOrQuittingWithoutTheDraftQuestion() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let watches = WatchState(
            service: WatchService(coordinator: coordinator), pause: PauseGate().pause)
        let jobs = JobState(service: JobService(coordinator: coordinator))
        let editing = WorkshopEditing(
            watches: watches,
            calibers: CaliberState(service: CaliberService(coordinator: coordinator)),
            jobs: jobs,
            notes: RecordNotesState(service: RecordNotesService(coordinator: coordinator)),
            material: MaterialState(service: MaterialService(coordinator: coordinator)),
            checklist: ChecklistState(service: ChecklistService(coordinator: coordinator)),
            parts: PartState(service: PartService(coordinator: coordinator)))
        let observations = [Task { await watches.observe() }, Task { await jobs.observe() }]
        defer { observations.forEach { $0.cancel() } }
        try await waitUntil { !watches.isLoading && !jobs.isLoading }
        let watchID = try #require(job.watchID)
        let facts = try #require(watches.facts(for: watchID))
        facts.owner.beginEditing()
        facts.owner.change(to: "Ana Ribeiro", undoManager: nil)
        #expect(editing.hasUnsavedFields)
        var navigated = false
        editing.requestNavigation { navigated = true }
        #expect(navigated)
        try await waitUntil { !facts.owner.hasUnsavedChanges }
        #expect(try await owner(of: watchID, coordinator) == "Ana Ribeiro")
        facts.contact.beginEditing()
        facts.contact.change(to: "ana@example.pt", undoManager: nil)
        #expect(await editing.saveAllFields())
        #expect(!editing.hasUnsavedFields)
        #expect(
            try await coordinator.read { try WatchQueries.fetch(watchID, in: $0)?.contact }
                == "ana@example.pt")

        // An archived watch can't change, but its open job still can.
        watches.select(watchID)
        #expect(await watches.toggleArchive())
        try await waitUntil { watches.selectedWatch?.archivedAt != nil }
        #expect(!editing.canWrite(.watch(watchID)))
        #expect(editing.canWrite(.job(job.id)))
        observations.forEach { $0.cancel() }
        for observation in observations { await observation.value }
        try await coordinator.close()
    }

    private func owner(of id: UUID, _ coordinator: LibraryCoordinator) async throws -> String? {
        try await coordinator.read { try WatchQueries.fetch(id, in: $0)?.owner }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WorkshopEditingTimeout()
    }
}

nonisolated private struct WorkshopEditingTimeout: Error {}
