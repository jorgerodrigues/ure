import Foundation
import GRDB
import Testing

@testable import Ure

struct WorkshopEditingTests {
    @Test(.timeLimit(.minutes(1)))
    func menuCancelPreservesSavedRecordsAndCannotDismissPendingNavigation() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let watch = try await WatchService(coordinator: coordinator).make("Bench watch")
        let session = WorkshopSession(
            coordinator: coordinator, configuration: AppConfiguration(libraryRoot: fixture.root))
        let editing = session.editing
        let observations = [
            Task { await session.watches.observe() }, Task { await session.jobs.observe() },
        ]
        defer { observations.forEach { $0.cancel() } }
        try await waitUntil { !session.watches.isLoading && !session.jobs.isLoading }
        #expect(!editing.canCancelDraft)
        session.jobs.start(for: watch.id)
        #expect(!editing.hasUnsavedChanges && editing.canCancelDraft)
        editing.cancelDraft()
        #expect(session.jobs.draft == nil)
        session.jobs.start(for: watch.id)
        session.jobs.draft?.title = "Keep this draft"
        var navigated = false
        editing.requestNavigation { navigated = true }
        #expect(!editing.canCancelDraft)
        editing.cancelDraft()
        #expect(!navigated && editing.isNavigationPending)
        #expect(editing.unsavedChangesTitle == "Save changes to this job?")
        #expect(session.jobs.draft?.title == "Keep this draft")
        editing.stay()
        #expect(editing.canCancelDraft)
        editing.cancelDraft()
        #expect(session.jobs.draft == nil)
        #expect(try await coordinator.read(JobQueries.fetchAll).isEmpty)
        observations.forEach { $0.cancel() }
        for observation in observations { await observation.value }
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
            tasks: JobTaskState(service: JobTaskService(coordinator: coordinator)),
            parts: PartState(service: PartService(coordinator: coordinator)))
        let observations = [Task { await watches.observe() }, Task { await jobs.observe() }]
        defer { observations.forEach { $0.cancel() } }
        try await waitUntil { !watches.isLoading && !jobs.isLoading }
        let facts = try #require(watches.facts(for: job.watchID))
        facts.owner.beginEditing()
        facts.owner.change(to: "Ana Ribeiro", undoManager: nil)
        #expect(editing.hasUnsavedFields && !editing.hasUnsavedChanges)
        var navigated = false
        editing.requestNavigation { navigated = true }
        #expect(navigated && !editing.showsUnsavedChanges)
        try await waitUntil { !facts.owner.hasUnsavedChanges }
        #expect(try await owner(of: job.watchID, coordinator) == "Ana Ribeiro")
        facts.contact.beginEditing()
        facts.contact.change(to: "ana@example.pt", undoManager: nil)
        #expect(await editing.saveAllFields())
        #expect(!editing.hasUnsavedFields)
        #expect(
            try await coordinator.read { try WatchQueries.fetch(job.watchID, in: $0)?.contact }
                == "ana@example.pt")

        // An archived watch can't change, but its open job still can.
        watches.select(job.watchID)
        #expect(await watches.toggleArchive())
        try await waitUntil { watches.selectedWatch?.archivedAt != nil }
        #expect(!editing.canWrite(.watch(job.watchID)))
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
