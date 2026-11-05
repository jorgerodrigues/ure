import Foundation
import GRDB
import Testing

@testable import Ure

struct WorkshopOverviewStateTests {
    @Test(.timeLimit(.minutes(1)))
    func observationRefreshesCommittedWorkAndClosureWhileFailuresStayExplicit() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { date }))
        let workshop = WorkshopOverviewState(coordinator: coordinator)
        await workshop.observe()
        #expect(!workshop.isLoading && workshop.loadError != nil)
        _ = try await coordinator.open()
        let observation = Task { await workshop.observe() }
        defer { observation.cancel() }
        try await waitUntil { !workshop.isLoading && workshop.loadError == nil }
        #expect(workshop.rows.isEmpty)
        let job = try await JobTaskFixture.job(coordinator)
        try await waitUntil { workshop.rows.count == 1 }
        #expect(workshop.rows.first?.progress.percentage == nil)
        let taskService = JobTaskService(coordinator: coordinator)
        let task = try await taskService.save(
            JobTaskFixture.draft(.done), for: job.id, editing: nil)
        try await waitUntil { workshop.rows.first?.progress.percentage == 100 }
        var reopened = JobTaskDraft(task: task)
        reopened.status = .doing
        _ = try await taskService.save(reopened, for: job.id, editing: task.id)
        try await waitUntil { workshop.rows.first?.progress.percentage == 0 }
        let parts = PartService(coordinator: coordinator)
        let part = try await parts.save(PartFixture.draft(), for: job.id, editing: nil)
        try await waitUntil { workshop.rows.first?.unresolvedPartCount == 1 }
        var arrived = PartDraft(part: part)
        arrived.status = .arrived
        try await JobTaskFixture.failWrites(coordinator, on: "partRequirement")
        await #expect(throws: DatabaseError.self) {
            try await parts.save(arrived, for: job.id, editing: part.id)
        }
        #expect(workshop.rows.first?.unresolvedPartCount == 1)
        try await JobTaskFixture.allowWrites(coordinator, on: "partRequirement")
        _ = try await parts.save(arrived, for: job.id, editing: part.id)
        try await waitUntil { workshop.rows.first?.unresolvedPartCount == 0 }
        let jobs = JobService(coordinator: coordinator)
        _ = try await jobs.setStage(job.id, to: .waiting)
        _ = try await jobs.update(job.id, .waitingFor("A review Å時計"))
        try await waitUntil { workshop.rows.first?.job.waitingFor == "A review Å時計" }
        _ = try await WatchService(coordinator: coordinator).update(
            job.watchID, .name("Updated watch"))
        try await waitUntil { workshop.rows.first?.watch.name == "Updated watch" }
        let closed = try await jobs.setStage(job.id, to: .done).job
        try await waitUntil { workshop.rows.isEmpty }
        #expect(
            workshop.selectionMessage(for: closed)
                == "This job is done. It stays on its watch’s page.")
        #expect(try await coordinator.read { try JobQueries.fetch(job.id, in: $0) } == closed)
        _ = try await jobs.setStage(job.id, to: .inProgress)
        try await waitUntil { workshop.rows.first?.job.stage == .inProgress }
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func combinedFiltersKeepSelectionAndNavigationProtectsAndClearsChildDrafts() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { date }))
        _ = try await coordinator.open()
        let first = try await JobTaskFixture.job(coordinator)
        let second = try await JobTaskFixture.job(coordinator)
        _ = try await JobService(coordinator: coordinator).setStage(second.id, to: .waiting)
        _ = try await JobService(coordinator: coordinator).update(
            second.id, .waitingFor("A mainspring"))
        let task = try await JobTaskService(coordinator: coordinator).save(
            JobTaskFixture.draft(.toDo), for: first.id, editing: nil)
        let editing = makeEditing(coordinator)
        let workshop = WorkshopOverviewState(coordinator: coordinator)
        let observations = [
            Task { await workshop.observe() }, Task { await editing.watches.observe() },
            Task { await editing.jobs.observe() }, Task { await editing.tasks.observe() },
        ]
        defer { observations.forEach { $0.cancel() } }
        try await waitUntil {
            !workshop.isLoading && !editing.watches.isLoading && !editing.jobs.isLoading
                && !editing.tasks.isLoading
        }
        workshop.open(first.id, editing: editing)
        #expect(editing.jobs.selectedID == first.id && editing.watches.selectedID == first.watchID)
        workshop.stageFilter = .waiting
        workshop.searchText = "  MAINSPRING \n"
        #expect(workshop.filteredRows.map(\.id) == [second.id])
        #expect(workshop.selectionMessage(for: editing.jobs.selectedJob) != nil)
        #expect(editing.jobs.selectedID == first.id)
        workshop.searchText = "crystal"
        #expect(workshop.filteredRows.isEmpty)
        workshop.clearFilters()
        #expect(workshop.selectionMessage(for: editing.jobs.selectedJob) == nil)
        for stage in JobStage.allCases.filter(\.isOpen) {
            workshop.stageFilter = stage
            #expect(workshop.filteredRows.allSatisfy { $0.job.stage == stage })
        }
        workshop.clearFilters()
        workshop.searchText = "omega"
        #expect(workshop.filteredRows.count == 2)
        workshop.searchText = "SERVICE MOVEMENT"
        #expect(workshop.filteredRows.count == 2)
        workshop.searchText = "Does not exist"
        #expect(workshop.filteredRows.isEmpty)
        workshop.clearFilters()
        editing.tasks.open(task, for: first.id)
        editing.tasks.edit(jobs: editing.jobs)
        editing.tasks.draft?.title = "Keep my draft"
        workshop.open(second.id, editing: editing)
        #expect(editing.showsUnsavedChanges && editing.jobs.selectedID == first.id)
        editing.stay()
        #expect(editing.tasks.draft?.title == "Keep my draft")
        workshop.open(second.id, editing: editing)
        await editing.saveAndContinue()
        #expect(
            editing.jobs.selectedID == second.id && editing.watches.selectedID == second.watchID)
        #expect(
            editing.tasks.jobID == nil && editing.parts.jobID == nil)
        let saved = try await coordinator.read { try JobTaskQueries.fetch(task.id, in: $0) }
        #expect(saved?.title == "Keep my draft")
        workshop.open(UUID(), editing: editing)
        #expect(workshop.navigationError != nil && editing.jobs.selectedID == second.id)
        _ = try await JobService(coordinator: coordinator).setStage(second.id, to: .done)
        try await waitUntil {
            workshop.rows.count == 1 && editing.jobs.selectedJob?.stage == .done
        }
        workshop.open(second.id, editing: editing)
        #expect(workshop.navigationError != nil && editing.jobs.selectedID == second.id)
        for observation in observations { observation.cancel(); await observation.value }
        try await coordinator.close()
    }

    private func makeEditing(_ coordinator: LibraryCoordinator) -> WorkshopEditing {
        WorkshopEditing(
            watches: WatchState(service: WatchService(coordinator: coordinator)),
            calibers: CaliberState(service: CaliberService(coordinator: coordinator)),
            jobs: JobState(service: JobService(coordinator: coordinator)),
            notes: RecordNotesState(service: RecordNotesService(coordinator: coordinator)),
            material: MaterialState(service: MaterialService(coordinator: coordinator)),
            tasks: JobTaskState(service: JobTaskService(coordinator: coordinator)),
            parts: PartState(service: PartService(coordinator: coordinator)))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WorkshopObservationTimeout()
    }
}

nonisolated private struct WorkshopObservationTimeout: Error {}
