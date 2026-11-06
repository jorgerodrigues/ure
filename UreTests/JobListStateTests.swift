import Foundation
import GRDB
import Testing

@testable import Ure

struct JobListStateTests {
    @Test(.timeLimit(.minutes(1)))
    func observationRefreshesTheWorkAndMovesADoneJobToDoneRecently() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let now = try JobListTests.now()
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { now }))
        let list = JobListState(
            coordinator: coordinator, now: { now }, calendar: JobListTests.calendar)
        await list.observe()
        #expect(!list.isLoading && list.loadError != nil)
        _ = try await coordinator.open()
        let observation = Task { await list.observe() }
        defer { observation.cancel() }
        try await JobListFixture.waitUntil { !list.isLoading && list.loadError == nil }
        #expect(list.rows.isEmpty && list.subtitle == "No open jobs")
        let job = try await JobTaskFixture.job(coordinator)
        try await JobListFixture.waitUntil { list.rows.count == 1 }
        #expect(list.rows.first?.progress.stepCount == 0)
        _ = try await ChecklistService(coordinator: coordinator).save(
            [ChecklistStep(id: UUID(), text: "Clean all parts", isTicked: true)], for: job.id)
        try await JobListFixture.waitUntil { list.rows.first?.progress.doneCount == 1 }
        let parts = PartService(coordinator: coordinator)
        let part = try await parts.add(named: "Mainspring", to: job.id)
        try await JobListFixture.waitUntil { list.rows.first?.partsToBuy == 1 }
        try await JobTaskFixture.failWrites(coordinator, on: "part")
        await #expect(throws: DatabaseError.self) { try await parts.advance(part.id) }
        #expect(list.rows.first?.partsToBuy == 1)
        try await JobTaskFixture.allowWrites(coordinator, on: "part")
        _ = try await parts.advance(part.id)
        try await JobListFixture.waitUntil { list.rows.first?.partsToBuy == 0 }
        let jobs = JobService(coordinator: coordinator)
        _ = try await jobs.setStage(job.id, to: .waiting)
        _ = try await jobs.update(job.id, .waitingFor("a review Å時計"))
        try await JobListFixture.waitUntil { list.rows(in: .waiting).count == 1 }
        #expect(list.subtitle == "1 open · 1 waiting")
        _ = try await WatchService(coordinator: coordinator).update(
            try #require(job.watchID), .name("Updated watch"))
        try await JobListFixture.waitUntil { list.rows.first?.watch?.name == "Updated watch" }

        // A Done job moves to Done recently, and leaves the list once it is older.
        let done = try await jobs.setStage(job.id, to: .done).job
        try await JobListFixture.waitUntil { list.rows(in: .doneRecently).map(\.id) == [job.id] }
        #expect(list.selectionMessage(for: done) == nil)
        let longAgo = try JobListTests.daysAgo(31).timeIntervalSince1970
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: "UPDATE job SET doneAt = ? WHERE id = ?",
                arguments: [longAgo, job.id.uuidString])
        }
        try await JobListFixture.waitUntil { list.listedRows.isEmpty }
        let old = try #require(try await coordinator.read { try JobQueries.fetch(job.id, in: $0) })
        #expect(
            list.selectionMessage(for: old)
                == "This job was done more than 30 days ago. It stays on its watch’s page.")
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func searchKeepsTheSelectionAndOpeningAJobGuardsDraftsAndSelectsItsWatch() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let now = try JobListTests.now()
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { now }))
        _ = try await coordinator.open()
        let jobs = JobService(coordinator: coordinator)
        let first = try await JobTaskFixture.job(coordinator)
        let second = try await JobTaskFixture.job(coordinator)
        _ = try await jobs.setStage(second.id, to: .waiting)
        _ = try await jobs.update(second.id, .waitingFor("A mainspring"))
        let unwatched = try await jobs.start(for: nil, title: "New crystal")
        let part = try await PartService(coordinator: coordinator).add(
            named: "Mainspring", to: first.id)
        let editing = JobListFixture.editing(coordinator)
        let list = JobListState(
            coordinator: coordinator, now: { now }, calendar: JobListTests.calendar)
        let observations = [
            Task { await list.observe() }, Task { await editing.watches.observe() },
            Task { await editing.jobs.observe() }, Task { await editing.parts.observe() },
        ]
        defer { observations.forEach { $0.cancel() } }
        try await JobListFixture.waitUntil {
            !list.isLoading && !editing.watches.isLoading && !editing.jobs.isLoading
                && !editing.parts.isLoading
        }
        list.open(first.id, editing: editing)
        #expect(editing.jobs.selectedID == first.id && editing.watches.selectedID == first.watchID)
        list.searchText = "  MAINSPRING \n"
        #expect(list.filteredRows.map(\.id) == [second.id])
        #expect(
            list.selectionMessage(for: editing.jobs.selectedJob)
                == "The selected job is outside the current search. Its page stays open.")
        #expect(editing.jobs.selectedID == first.id)
        list.searchText = "omega"
        #expect(Set(list.filteredRows.map(\.id)) == [first.id, second.id])
        list.searchText = "crystal"
        #expect(list.filteredRows.map(\.id) == [unwatched.id])
        list.clearSearch()
        #expect(list.selectionMessage(for: editing.jobs.selectedJob) == nil)

        // A part's typing saves as another job opens, without a question.
        let facts = try #require(editing.parts.facts(for: part.id))
        facts.name.beginEditing()
        facts.name.change(to: "Keep my typing", undoManager: nil)
        list.open(second.id, editing: editing)
        #expect(
            editing.jobs.selectedID == second.id && editing.watches.selectedID == second.watchID)
        try await JobListFixture.waitUntil { !facts.name.hasUnsavedChanges }
        let saved = try await coordinator.read { try PartQueries.fetch(part.id, in: $0) }
        #expect(saved?.name == "Keep my typing")

        // A job without a watch opens with no watch selected, and can still be written on.
        list.open(unwatched.id, editing: editing)
        #expect(editing.jobs.selectedID == unwatched.id && editing.watches.selectedID == nil)
        #expect(editing.jobs.watchID == nil && editing.canWrite(.job(unwatched.id)))
        list.open(UUID(), editing: editing)
        #expect(list.navigationError != nil && editing.jobs.selectedID == unwatched.id)
        for observation in observations {
            observation.cancel()
            await observation.value
        }
        try await coordinator.close()
    }
}

extension JobListFixture {
    @MainActor
    static func editing(_ coordinator: LibraryCoordinator) -> WorkshopEditing {
        EditingFixture.make(coordinator)
    }
}
