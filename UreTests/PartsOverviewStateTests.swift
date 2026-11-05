import Foundation
import GRDB
import Testing

@testable import Ure

struct PartsOverviewStateTests {
    @Test(.timeLimit(.minutes(1)))
    func observationsKeepProcurementAndContextConsistentAndRollbackInvisible() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { date }))
        let overview = PartsOverviewState(coordinator: coordinator)
        await overview.observe()
        #expect(!overview.isLoading && overview.loadError != nil)
        overview.retry()
        #expect(overview.observationRevision == 1)
        _ = try await coordinator.open()
        let editing = makeEditing(coordinator)
        let observations = observe(overview, editing: editing)
        defer { observations.forEach { $0.cancel() } }
        try await waitUntil { !overview.isLoading && overview.loadError == nil }
        #expect(overview.rows.isEmpty)
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        let part = try await service.save(PartFixture.draft(), for: job.id, editing: nil)
        try await waitUntil {
            overview.rows.count == 1 && editing.parts.records(for: job.id).count == 1
        }
        var arrived = PartDraft(part: part)
        arrived.status = .arrived
        try await JobTaskFixture.failWrites(coordinator, on: "partRequirement")
        await #expect(throws: DatabaseError.self) {
            try await service.save(arrived, for: job.id, editing: part.id)
        }
        #expect(overview.rows.first?.part.status == .needed)
        #expect(editing.parts.records(for: job.id).first?.record.status == .needed)
        try await JobTaskFixture.allowWrites(coordinator, on: "partRequirement")
        _ = try await service.save(arrived, for: job.id, editing: part.id)
        try await waitUntil {
            overview.rows.first?.part.status == .arrived
                && editing.parts.records(for: job.id).first?.record.status == .arrived
        }
        let watch = try await WatchService(coordinator: coordinator).update(
            job.watchID, .name("Corrected watch Å時計"))
        _ = try await JobService(coordinator: coordinator).update(
            job.id, .title("Corrected repair"))
        try await waitUntil {
            overview.rows.first?.watch.name == watch.name
                && overview.rows.first?.job.title == "Corrected repair"
        }
        let closed = try await JobService(coordinator: coordinator).setStage(job.id, to: .done).job
        try await waitUntil { overview.rows.isEmpty }
        #expect(
            overview.selectionMessage(part: part, job: closed)
                == "This job is done. Its parts stay on its page.")
        #expect(try await coordinator.read(PartQueries.fetchAll).first?.id == part.id)
        _ = try await JobService(coordinator: coordinator).setStage(job.id, to: .waiting)
        try await waitUntil { overview.rows.first?.job.stage == .waiting }
        for observation in observations { observation.cancel(); await observation.value }
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func exactNavigationAndFiltersProtectDraftsAndNeverOpenPartLinks() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { date }))
        _ = try await coordinator.open()
        let first = try await JobTaskFixture.job(coordinator)
        let second = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        var draft = PartFixture.draft()
        draft.manufacturerReference = "0012–Å/04"
        draft.links = [PartLinkDraft(url: "https://example.org/supplier")]
        let part = try await service.save(draft, for: first.id, editing: nil)
        draft.status = .arrived
        draft.links = [PartLinkDraft(url: "https://example.org/second-supplier")]
        let other = try await service.save(draft, for: second.id, editing: nil)
        let browser = OverviewBrowserSpy()
        let editing = makeEditing(coordinator, openBrowser: browser.open)
        let overview = PartsOverviewState(coordinator: coordinator)
        let observations = observe(overview, editing: editing)
        defer { observations.forEach { $0.cancel() } }
        try await waitUntil {
            !overview.isLoading && !editing.parts.isLoading && !editing.jobs.isLoading
                && !editing.watches.isLoading && !editing.checklist.isLoading
        }
        overview.open(part.id, editing: editing)
        #expect(editing.parts.selectedID == part.id && editing.jobs.selectedID == first.id)
        #expect(editing.watches.selectedID == first.watchID && browser.opened.isEmpty)
        #expect(overview.selectedID(editing: editing) == part.id)
        editing.jobs.close()
        #expect(overview.selectedID(editing: editing) == nil)
        overview.open(part.id, editing: editing)
        #expect(overview.selectedID(editing: editing) == part.id)
        editing.watches.select(second.watchID)
        editing.jobs.open(second)
        #expect(overview.selectedID(editing: editing) == nil)
        overview.statusFilter = .ordered
        #expect(
            overview.selectionMessage(
                part: editing.parts.selectedPart, job: editing.jobs.selectedJob)
                == nil)
        overview.open(part.id, editing: editing)
        #expect(overview.selectedID(editing: editing) == part.id)
        for status in PartStatus.allCases {
            overview.statusFilter = status
            let expected = overview.rows.filter { $0.part.status == status }.map(\.id)
            #expect(overview.filteredRows.map(\.id) == expected)
        }
        overview.statusFilter = .arrived
        overview.searchText = "  omega \n"
        #expect(overview.filteredRows.map(\.id) == [other.id])
        #expect(overview.selectionMessage(part: part, job: first) != nil)
        #expect(overview.selectedID(editing: editing) == part.id)
        #expect(editing.parts.selectedID == part.id)
        overview.searchText = "Missing part"
        #expect(overview.filteredRows.isEmpty)
        overview.clearFilters()
        #expect(overview.selectionMessage(part: part, job: first) == nil)
        overview.searchText = "  0012 \n"
        #expect(overview.filteredRows.count == 2)
        overview.clearFilters()
        editing.parts.edit(jobs: editing.jobs)
        editing.parts.draft?.description = "Keep my correction"
        overview.open(other.id, editing: editing)
        #expect(editing.showsUnsavedChanges && editing.parts.selectedID == part.id)
        editing.stay()
        #expect(editing.parts.draft?.description == "Keep my correction")
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: """
                    CREATE TRIGGER failOverviewPart BEFORE UPDATE ON partRequirement
                    BEGIN SELECT RAISE(ABORT, 'fixture disk failure'); END
                    """)
        }
        overview.open(other.id, editing: editing)
        await editing.saveAndContinue()
        #expect(editing.parts.selectedID == part.id && editing.parts.saveError != nil)
        #expect(editing.parts.draft?.description == "Keep my correction")
        try await coordinator.mutate { db, _, _ in
            try db.execute(sql: "DROP TRIGGER failOverviewPart")
        }
        overview.open(other.id, editing: editing)
        await editing.saveAndContinue()
        #expect(editing.parts.selectedID == other.id && editing.jobs.selectedID == second.id)
        #expect(editing.watches.selectedID == second.watchID)
        #expect(editing.material.presented == nil)
        try await waitUntil {
            overview.rows.contains { $0.part.description == "Keep my correction" }
        }
        #expect(browser.opened.isEmpty)
        overview.open(UUID(), editing: editing)
        #expect(overview.navigationError != nil && editing.parts.selectedID == other.id)
        _ = try await JobService(coordinator: coordinator).setStage(second.id, to: .done)
        try await waitUntil {
            overview.rows.count == 1 && editing.jobs.selectedJob?.stage == .done
        }
        overview.open(other.id, editing: editing)
        #expect(overview.navigationError != nil && editing.parts.selectedID == other.id)
        // A Done job's parts leave the overview but can still change on its page.
        #expect(editing.parts.canWrite(second.id, jobs: editing.jobs))
        for observation in observations { observation.cancel(); await observation.value }
        try await coordinator.close()
    }

    private func makeEditing(
        _ coordinator: LibraryCoordinator,
        openBrowser: @escaping @MainActor @Sendable (URL) -> Bool = { _ in false }
    ) -> WorkshopEditing {
        WorkshopEditing(
            watches: WatchState(service: WatchService(coordinator: coordinator)),
            calibers: CaliberState(service: CaliberService(coordinator: coordinator)),
            jobs: JobState(service: JobService(coordinator: coordinator)),
            notes: RecordNotesState(service: RecordNotesService(coordinator: coordinator)),
            material: MaterialState(service: MaterialService(coordinator: coordinator)),
            checklist: ChecklistState(service: ChecklistService(coordinator: coordinator)),
            parts: PartState(
                service: PartService(coordinator: coordinator, openBrowser: openBrowser)))
    }

    private func observe(_ overview: PartsOverviewState, editing: WorkshopEditing) -> [Task<
        Void, Never
    >] {
        [
            Task { await overview.observe() }, Task { await editing.parts.observe() },
            Task { await editing.jobs.observe() }, Task { await editing.watches.observe() },
            Task { await editing.checklist.observe() },
        ]
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PartsOverviewTimeout()
    }
}

nonisolated private struct PartsOverviewTimeout: Error {}

private final class OverviewBrowserSpy {
    var opened: [URL] = []
    func open(_ url: URL) -> Bool { opened.append(url); return true }
}
