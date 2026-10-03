import Foundation
import GRDB
import Testing

@testable import Ure

struct PartStateTests {
    @Test(.timeLimit(.minutes(1)))
    func validationNavigationAndFailedWritesKeepTheWholeDraft() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let (state, jobs, observations) = try await makeState(coordinator)
        defer { observations.forEach { $0.cancel() } }
        let editing = makeEditing(coordinator, parts: state, jobs: jobs)
        #expect(state.records(for: job.id).isEmpty)
        state.create(for: job.id, jobs: jobs)
        #expect(!(await state.save()))
        #expect(state.fieldErrors[.description] != nil)
        state.draft?.description = "Keep my part"
        state.draft?.quantity = "0"
        state.addLink()
        let link = try #require(state.draft?.links.first)
        state.setLinkURL("file:///tmp/part", id: link.id)
        #expect(!(await state.save()))
        #expect(state.fieldErrors[.quantity] != nil && state.fieldErrors[.link(link.id)] != nil)
        state.draft?.quantity = "2"
        state.setLinkURL("https://example.org/part", id: link.id)
        var navigated = false
        editing.requestNavigation { navigated = true }
        #expect(editing.unsavedChangesTitle == "Save changes to this part?")
        #expect(editing.hasUnsavedChanges && editing.showsUnsavedChanges)
        editing.stay()
        #expect(!navigated && !editing.isNavigationPending)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: """
                    CREATE TRIGGER failPart BEFORE INSERT ON partLink
                    BEGIN SELECT RAISE(ABORT, 'fixture disk failure'); END
                    """)
        }
        let draft = state.draft
        var cancelled = false
        editing.requestNavigation({ navigated = true }, onCancel: { cancelled = true })
        await editing.saveAndContinue()
        #expect(!navigated && cancelled && state.draft == draft)
        #expect(state.saveError != nil && !editing.isNavigationPending)
        #expect(try await coordinator.read(PartQueries.fetchAll).isEmpty)
        try await coordinator.mutate { db, _, _ in try db.execute(sql: "DROP TRIGGER failPart") }
        editing.requestNavigation { navigated = true }
        await editing.saveAndContinue()
        #expect(navigated && !editing.hasUnsavedChanges)
        #expect(state.selectedPart?.record.quantity == 2 && state.selectedPart?.links.count == 1)
        state.edit(jobs: jobs)
        state.removeLink(link.id)
        #expect(state.linkToRemove == link.id && state.draft?.links.count == 1)
        state.confirmRemoveLink()
        #expect(state.draft?.links.isEmpty == true)
        state.addLink()
        let unsaved = try #require(state.draft?.links.first)
        state.removeLink(unsaved.id)
        #expect(state.draft?.links.isEmpty == true && state.linkToRemove == nil)
        editing.requestNavigation(state.close)
        editing.discardAndContinue()
        #expect(state.jobID == nil && state.draft == nil)
        #expect(state.parts.first?.links.count == 1)
        for observation in observations { observation.cancel(); await observation.value }
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingSaveBlocksDuplicatesAndSharedNavigation() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let (state, jobs, observations) = try await makeState(coordinator)
        defer { observations.forEach { $0.cancel() } }
        let editing = makeEditing(coordinator, parts: state, jobs: jobs)
        state.create(for: job.id, jobs: jobs)
        state.draft = PartFixture.draft()
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
        let saving = Task { await state.save() }
        try await waitUntil { state.isSaving }
        #expect(editing.isSaving && !state.canSave(jobs: jobs))
        #expect(!(await state.save()))
        var navigated = false
        editing.requestNavigation { navigated = true }
        state.cancel()
        state.addLink()
        #expect(!navigated && state.draft?.links.isEmpty == true)
        gate.signal()
        try await blocker.value
        #expect(await saving.value)
        #expect(try await coordinator.read(PartQueries.fetchAll).count == 1)
        for observation in observations { observation.cancel(); await observation.value }
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func observationKeepsDraftsAndClosedJobsRejectStaleEditors() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let other = try await JobTaskFixture.job(coordinator)
        let (state, jobs, observations) = try await makeState(coordinator)
        defer { observations.forEach { $0.cancel() } }
        state.create(for: job.id, jobs: jobs)
        state.draft = PartFixture.draft()
        #expect(await state.save())
        let saved = try #require(state.selectedPart)
        state.open(saved, for: other.id)
        #expect(state.jobID == job.id && state.records(for: other.id).isEmpty)
        state.edit(jobs: jobs)
        state.draft?.manufacturerReference = "Keep 0012/3"
        var external = PartDraft(part: saved)
        external.quantity = "3"
        let updated = try await PartService(coordinator: coordinator).save(
            external, for: job.id, editing: saved.id)
        try await waitUntil { state.selectedPart == updated }
        #expect(state.draft?.quantity == "1" && state.draft?.manufacturerReference == "Keep 0012/3")
        var closure = JobTransitionDraft(stage: .completed)
        closure.outcome = "Inspection complete"
        closure.unfinishedPartsReason = "Owner will source it"
        let closed = try await JobService(coordinator: coordinator).transition(
            job.id, using: closure)
        try await waitUntil { jobs.jobs.contains(closed) }
        #expect(!state.canSave(jobs: jobs) && !state.canWrite(job.id, jobs: jobs))
        #expect(!(await state.save()))
        #expect(state.draft?.manufacturerReference == "Keep 0012/3")
        #expect(state.saveError == JobError.closedJob.localizedDescription)
        state.cancel()
        state.create(for: job.id, jobs: jobs)
        state.edit(jobs: jobs)
        #expect(state.draft == nil && state.selectedPart == updated)
        for observation in observations { observation.cancel(); await observation.value }
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func loadRetryAndExplicitOpenAreIndependentOfSaveAndSelection() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        let browser = PartBrowserSpy()
        let service = PartService(coordinator: coordinator, openBrowser: browser.open)
        let state = PartState(service: service)
        await state.observe()
        #expect(state.loadError != nil && !state.isLoading)
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let jobs = JobState(service: JobService(coordinator: coordinator))
        let observations = [Task { await state.observe() }, Task { await jobs.observe() }]
        defer { observations.forEach { $0.cancel() } }
        try await waitUntil { !state.isLoading && state.loadError == nil && !jobs.isLoading }
        state.create(for: job.id, jobs: jobs)
        state.draft = PartFixture.draft()
        state.addLink()
        let draftLink = try #require(state.draft?.links.first)
        state.setLinkURL("https://example.org/part", id: draftLink.id)
        #expect(await state.save())
        let part = try #require(state.selectedPart)
        state.close()
        state.open(part, for: job.id)
        #expect(browser.opened.isEmpty)
        let link = try #require(part.links.first)
        state.openLink(link)
        #expect(browser.opened.map(\.absoluteString) == [link.url])
        browser.isAvailable = false
        state.openLink(link)
        #expect(state.openError == ReferenceError.browserUnavailable.localizedDescription)
        let invalid = PartLink(
            id: UUID(), partID: part.id, position: 0, url: "file:///tmp/part", createdAt: Date(),
            updatedAt: Date())
        #expect(throws: ReferenceError.invalidURL) { try service.open(invalid) }
        #expect(browser.opened.count == 2)
        for observation in observations { observation.cancel(); await observation.value }
        try await coordinator.close()
    }

    private func makeState(_ coordinator: LibraryCoordinator) async throws -> (
        PartState, JobState, [Task<Void, Never>]
    ) {
        let state = PartState(service: PartService(coordinator: coordinator))
        let jobs = JobState(service: JobService(coordinator: coordinator))
        let observations = [Task { await state.observe() }, Task { await jobs.observe() }]
        do { try await waitUntil { !state.isLoading && !jobs.isLoading } } catch {
            observations.forEach { $0.cancel() }; throw error
        }
        return (state, jobs, observations)
    }

    private func makeEditing(_ coordinator: LibraryCoordinator, parts: PartState, jobs: JobState)
        -> WorkshopEditing
    {
        WorkshopEditing(
            watches: WatchState(service: WatchService(coordinator: coordinator)),
            calibers: CaliberState(service: CaliberService(coordinator: coordinator)), jobs: jobs,
            notes: NoteState(service: NoteService(coordinator: coordinator)),
            references: ReferenceState(service: ReferenceService(coordinator: coordinator)),
            photos: PhotoState(service: PhotoService(coordinator: coordinator)),
            documents: DocumentState(service: DocumentService(coordinator: coordinator)),
            tasks: JobTaskState(service: JobTaskService(coordinator: coordinator)), parts: parts)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PartObservationTimeout()
    }
}

nonisolated private struct PartObservationTimeout: Error {}

private final class PartBrowserSpy {
    var opened: [URL] = []
    var isAvailable = true

    func open(_ url: URL) -> Bool {
        opened.append(url)
        return isAvailable
    }
}
