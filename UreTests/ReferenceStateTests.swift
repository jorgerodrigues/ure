import Foundation
import GRDB
import Testing

@testable import Ure

struct ReferenceStateTests {
    @Test(.timeLimit(.minutes(1)))
    func loadingSavingAndSelectionNeverOpenBrowserAndOpenUsesSavedURL() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        let browser = ReferenceBrowserSpy()
        let state = ReferenceState(
            service: ReferenceService(
                coordinator: coordinator, openBrowser: browser.open))
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { !state.isLoading }
        #expect(browser.urls.isEmpty)
        state.create(for: owner)
        state.draft = ReferenceFixture.draft
        state.openInBrowser()
        #expect(browser.urls.isEmpty)
        #expect(await state.save())
        let saved = try #require(state.selectedReference)
        state.close()
        state.open(saved, for: owner)
        #expect(browser.urls.isEmpty)
        state.edit()
        state.draft?.sourceURL = "file:///tmp/forbidden.pdf"
        #expect(!(await state.save()))
        #expect(state.fieldErrors[.sourceURL] != nil)
        #expect(state.draft?.sourceURL == "file:///tmp/forbidden.pdf")
        state.openInBrowser()
        #expect(browser.urls.isEmpty)
        state.cancel()
        browser.succeeds = false
        state.openInBrowser()
        #expect(state.openError != nil)
        #expect(state.selectedReference == saved)
        browser.succeeds = true
        state.openInBrowser()
        #expect(state.openError == nil)
        #expect(browser.urls.map(\.absoluteString) == [saved.sourceURL, saved.sourceURL])
        browser.succeeds = false
        state.openInBrowser()
        #expect(state.openError != nil)
        state.close()
        state.create(for: owner)
        #expect(state.openError == nil)
        state.cancel()
        #expect(try await coordinator.read(LibraryItemQueries.fetchAll) == [saved])
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingSaveBlocksBrowserOpeningEditingAndSharedNavigation() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        let browser = ReferenceBrowserSpy()
        let state = ReferenceState(
            service: ReferenceService(
                coordinator: coordinator, openBrowser: browser.open))
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { !state.isLoading }
        state.create(for: owner)
        state.draft = ReferenceFixture.draft
        #expect(await state.save())
        let editing = WorkshopEditing(
            watches: WatchState(service: WatchService(coordinator: coordinator)),
            calibers: CaliberState(service: CaliberService(coordinator: coordinator)),
            jobs: JobState(service: JobService(coordinator: coordinator)),
            notes: NoteState(service: NoteService(coordinator: coordinator)), references: state,
            photos: PhotoState(service: PhotoService(coordinator: coordinator)),
            documents: DocumentState(service: DocumentService(coordinator: coordinator)))
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
        state.edit()
        state.draft?.notes = "Saved correction"
        let saving = Task { await state.save() }
        try await waitUntil { state.isSaving }
        #expect(editing.isSaving)
        state.openInBrowser()
        state.edit()
        state.close()
        var navigated = false
        var cancelled = false
        editing.requestNavigation({ navigated = true }, onCancel: { cancelled = true })
        #expect(cancelled)
        #expect(!navigated)
        #expect(state.draft?.notes == "Saved correction")
        #expect(browser.urls.isEmpty)
        #expect(state.owner == owner)
        gate.signal()
        try await blocker.value
        #expect(await saving.value)
        #expect(state.selectedReference?.notes == "Saved correction")
        state.openInBrowser()
        #expect(browser.urls.count == 1)
        #expect(!editing.isSaving)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func creationValidationCancellationAndScopeFiltering() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let (state, observation) = try await makeState(coordinator)
        defer { observation.cancel() }
        state.create(for: owners[0])
        state.draft?.sourceURL = ReferenceFixture.draft.sourceURL
        state.draft?.title = "Discarded reference"
        state.cancel()
        #expect(state.draft == nil)
        #expect(state.owner == nil)
        #expect(try await coordinator.read(LibraryItemQueries.fetchAll).isEmpty)
        state.create(for: owners[0])
        #expect(!(await state.save()))
        #expect(state.fieldErrors[.title] != nil)
        #expect(state.fieldErrors[.sourceURL] != nil)
        #expect(state.draft != nil)
        state.draft?.sourceURL = ReferenceFixture.draft.sourceURL
        state.draft?.title = "Watch finding"
        #expect(await state.save())
        let first = try #require(state.selectedReference)
        #expect(state.records(for: owners[0]) == [first])
        #expect(state.records(for: owners[1]).isEmpty)
        #expect(state.records(for: owners[2]).isEmpty)
        state.edit()
        state.draft?.notes = "Discarded correction"
        state.cancel()
        #expect(state.selectedReference == first)
        state.open(first, for: owners[2])
        #expect(state.owner == owners[0])
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func observedChangesRefreshSelectedReferenceWithoutReplacingDraft() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        let (state, observation) = try await makeState(coordinator)
        defer { observation.cancel() }
        state.create(for: owner)
        state.draft?.sourceURL = ReferenceFixture.draft.sourceURL
        state.draft?.title = "Saved reference"
        #expect(await state.save())
        let saved = try #require(state.selectedReference)
        state.edit()
        state.draft?.notes = "Keep this draft"
        var edit = ReferenceDraft(item: saved)
        edit.notes = "Committed correction"
        let updated = try await ReferenceService(coordinator: coordinator).save(
            edit, for: owner, editing: saved.id)
        try await waitUntil { state.selectedReference == updated }
        #expect(state.draft?.notes == "Keep this draft")
        state.cancel()
        #expect(state.selectedReference == updated)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func sharedGuardKeepsFailedDraftAndSupportsStaySaveDiscard() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        let (state, observation) = try await makeState(coordinator)
        defer { observation.cancel() }
        let editing = WorkshopEditing(
            watches: WatchState(service: WatchService(coordinator: coordinator)),
            calibers: CaliberState(service: CaliberService(coordinator: coordinator)),
            jobs: JobState(service: JobService(coordinator: coordinator)),
            notes: NoteState(service: NoteService(coordinator: coordinator)),
            references: state, photos: PhotoState(service: PhotoService(coordinator: coordinator)),
            documents: DocumentState(service: DocumentService(coordinator: coordinator)))
        state.create(for: owner)
        state.draft?.sourceURL = ReferenceFixture.draft.sourceURL
        state.draft?.title = "Keep this reference"
        var navigated = false
        editing.requestNavigation { navigated = true }
        #expect(editing.unsavedChangesTitle == "Save changes to this reference?")
        #expect(editing.showsUnsavedChanges)
        editing.stay()
        #expect(!navigated)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql:
                    "CREATE TRIGGER failReference BEFORE INSERT ON libraryItem BEGIN SELECT RAISE(ABORT, 'fixture disk failure'); END"
            )
        }
        var cancelled = false
        editing.requestNavigation({ navigated = true }, onCancel: { cancelled = true })
        await editing.saveAndContinue()
        #expect(!navigated)
        #expect(cancelled)
        #expect(state.draft?.title == "Keep this reference")
        #expect(state.saveError != nil)
        #expect(!editing.isNavigationPending)
        #expect(try await coordinator.read(LibraryItemQueries.fetchAll).isEmpty)
        try await coordinator.mutate { db, _, _ in try db.execute(sql: "DROP TRIGGER failReference")
        }
        editing.requestNavigation { navigated = true }
        await editing.saveAndContinue()
        #expect(navigated)
        #expect(state.selectedReference?.title == "Keep this reference")
        state.edit()
        state.draft?.sourceURL = ReferenceFixture.draft.sourceURL
        state.draft?.title = "Discard this change"
        editing.requestNavigation(state.close)
        editing.discardAndContinue()
        #expect(state.owner == nil)
        #expect(state.draft == nil)
        #expect(state.references.first?.title == "Keep this reference")
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingSaveBlocksDuplicateSaveCancelAndNavigation() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        let (state, observation) = try await makeState(coordinator)
        defer { observation.cancel() }
        state.create(for: owner)
        state.draft?.sourceURL = ReferenceFixture.draft.sourceURL
        state.draft?.title = "One reference"
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
        #expect(!(await state.save()))
        var navigated = false
        state.requestNavigation { navigated = true }
        state.cancel()
        #expect(!navigated)
        #expect(state.draft?.title == "One reference")
        gate.signal()
        try await blocker.value
        #expect(await saving.value)
        #expect(try await coordinator.read(LibraryItemQueries.fetchAll).count == 1)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func closedJobDisablesWritesAndStaleEditorKeepsRejectedDraft() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let owner = owners[1]
        guard case .job(let jobID) = owner else { throw NoteFixtureError() }
        let (state, observation) = try await makeState(coordinator)
        defer { observation.cancel() }
        let jobs = JobState(service: JobService(coordinator: coordinator))
        let jobObservation = Task { await jobs.observe() }
        defer { jobObservation.cancel() }
        try await waitUntil { !jobs.isLoading }
        #expect(state.canWrite(owner, jobs: jobs))
        state.create(for: owner)
        state.draft?.sourceURL = ReferenceFixture.draft.sourceURL
        state.draft?.title = "Job finding"
        #expect(await state.save())
        let saved = try #require(state.selectedReference)
        state.edit()
        state.draft?.notes = "Pending correction"
        var closure = JobTransitionDraft(stage: .completed)
        closure.outcome = "Serviced"
        let closed = try await JobService(coordinator: coordinator).transition(
            jobID, using: closure)
        try await waitUntil { jobs.jobs.contains(closed) }
        #expect(!state.canWrite(owner, jobs: jobs))
        #expect(state.canWrite(owners[0], jobs: jobs))
        #expect(!(await state.save()))
        #expect(state.draft?.notes == "Pending correction")
        #expect(state.selectedReference == saved)
        #expect(state.saveError != nil)
        _ = try await JobService(coordinator: coordinator).reopen(
            jobID, using: JobTransitionDraft(stage: .planned))
        #expect(await state.save())
        #expect(state.selectedReference?.notes == "Pending correction")
        observation.cancel()
        jobObservation.cancel()
        await observation.value
        await jobObservation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func loadFailureCanRetryAndPreventsStartingFromAnUnavailableList() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        let state = ReferenceState(service: ReferenceService(coordinator: coordinator))
        await state.observe()
        #expect(state.loadError != nil)
        state.create(for: .watch(UUID()))
        #expect(state.draft == nil)
        _ = try await coordinator.open()
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { !state.isLoading && state.loadError == nil }
        #expect(state.references.isEmpty)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    private func makeState(_ coordinator: LibraryCoordinator) async throws -> (
        ReferenceState, Task<Void, Never>
    ) {
        let state = ReferenceState(service: ReferenceService(coordinator: coordinator))
        let observation = Task { await state.observe() }
        do {
            try await waitUntil { !state.isLoading }
        } catch {
            observation.cancel()
            throw error
        }
        return (state, observation)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ReferenceObservationTimeout()
    }
}

nonisolated private struct ReferenceObservationTimeout: Error {}

private final class ReferenceBrowserSpy {
    var urls: [URL] = []
    var succeeds = true

    func open(_ url: URL) -> Bool {
        urls.append(url)
        return succeeds
    }
}
