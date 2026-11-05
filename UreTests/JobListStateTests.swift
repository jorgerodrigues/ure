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
        #expect(list.rows.first?.progress.countedCount == 0)
        let tasks = JobTaskService(coordinator: coordinator)
        _ = try await tasks.save(JobTaskFixture.draft(.done), for: job.id, editing: nil)
        try await JobListFixture.waitUntil { list.rows.first?.progress.doneCount == 1 }
        let parts = PartService(coordinator: coordinator)
        let part = try await parts.save(PartFixture.draft(), for: job.id, editing: nil)
        try await JobListFixture.waitUntil { list.rows.first?.partsToBuy == 1 }
        var ordered = PartDraft(part: part)
        ordered.status = .ordered
        try await JobTaskFixture.failWrites(coordinator, on: "partRequirement")
        await #expect(throws: DatabaseError.self) {
            try await parts.save(ordered, for: job.id, editing: part.id)
        }
        #expect(list.rows.first?.partsToBuy == 1)
        try await JobTaskFixture.allowWrites(coordinator, on: "partRequirement")
        _ = try await parts.save(ordered, for: job.id, editing: part.id)
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
        let task = try await JobTaskService(coordinator: coordinator).save(
            JobTaskFixture.draft(.toDo), for: first.id, editing: nil)
        let editing = JobListFixture.editing(coordinator)
        let list = JobListState(
            coordinator: coordinator, now: { now }, calendar: JobListTests.calendar)
        let observations = [
            Task { await list.observe() }, Task { await editing.watches.observe() },
            Task { await editing.jobs.observe() }, Task { await editing.tasks.observe() },
        ]
        defer { observations.forEach { $0.cancel() } }
        try await JobListFixture.waitUntil {
            !list.isLoading && !editing.watches.isLoading && !editing.jobs.isLoading
                && !editing.tasks.isLoading
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

        // A task draft asks before another job opens.
        editing.tasks.open(task, for: first.id)
        editing.tasks.edit(jobs: editing.jobs)
        editing.tasks.draft?.title = "Keep my draft"
        list.open(second.id, editing: editing)
        #expect(editing.showsUnsavedChanges && editing.jobs.selectedID == first.id)
        editing.stay()
        #expect(editing.tasks.draft?.title == "Keep my draft")
        list.open(second.id, editing: editing)
        await editing.saveAndContinue()
        #expect(
            editing.jobs.selectedID == second.id && editing.watches.selectedID == second.watchID)
        #expect(editing.tasks.jobID == nil && editing.parts.jobID == nil)
        let saved = try await coordinator.read { try JobTaskQueries.fetch(task.id, in: $0) }
        #expect(saved?.title == "Keep my draft")

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
        WorkshopEditing(
            watches: WatchState(service: WatchService(coordinator: coordinator)),
            calibers: CaliberState(service: CaliberService(coordinator: coordinator)),
            jobs: JobState(service: JobService(coordinator: coordinator)),
            notes: RecordNotesState(service: RecordNotesService(coordinator: coordinator)),
            material: MaterialState(service: MaterialService(coordinator: coordinator)),
            tasks: JobTaskState(service: JobTaskService(coordinator: coordinator)),
            parts: PartState(service: PartService(coordinator: coordinator)))
    }
}
