import Foundation
import PDFKit
import Testing

@testable import Ure

struct DocumentStateTests {
    @Test(.timeLimit(.minutes(1)))
    func sourceOpeningRequiresExplicitActionAndSharedGuardKeepsFailedDrafts() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let source = try DocumentFixture.source(in: fixture)
        let browser = DocumentBrowserSpy()
        let service = DocumentService(coordinator: coordinator, openBrowser: browser.open)
        let document = try await service.importFiles([source], for: owners[0])[0].outcome.get()
        let state = DocumentState(service: service)
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { !state.isLoading }
        #expect(state.records(for: owners[0]) == [document])
        #expect(state.records(for: owners[1]).isEmpty && state.records(for: owners[2]).isEmpty)
        state.open(document, for: owners[2])
        #expect(state.selectedID == nil)
        state.open(document, for: owners[0])
        state.edit()
        state.draft?.sourceURL = "https://example.com/source.pdf"
        state.draft?.notes = "Keep source context"
        let editing = makeEditing(coordinator, documents: state)
        var navigated = false
        editing.requestNavigation { navigated = true }
        #expect(!navigated && editing.showsUnsavedChanges)
        #expect(editing.unsavedChangesTitle == "Save changes to this document?")
        editing.stay()
        #expect(state.draft?.notes == "Keep source context")
        state.draft?.title = " "
        editing.requestNavigation { navigated = true }
        await editing.saveAndContinue()
        #expect(!navigated && state.fieldErrors[.title] != nil)
        #expect(state.draft?.notes == "Keep source context")
        state.draft?.title = "Technical sheet"
        state.draft?.sourceURL = "file:///bad.pdf"
        #expect(!(await state.save()) && state.fieldErrors[.sourceURL] != nil)
        state.draft?.sourceURL = "https://example.com/source.pdf"
        #expect(await state.save())
        #expect(browser.urls.isEmpty)
        state.openSource()
        #expect(browser.urls.map(\.absoluteString) == ["https://example.com/source.pdf"])
        browser.succeeds = false
        state.openSource()
        #expect(state.operationError != nil)
        state.edit()
        state.draft?.sourceDescription = "Discard this"
        editing.requestNavigation { navigated = true }
        editing.discardAndContinue()
        #expect(navigated && state.selectedDocument?.item.sourceDescription == "")
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingImportBlocksDuplicatesAndNavigationAndCancellationKeepsExistingDocuments()
        async throws
    {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let initial = LibraryCoordinator(root: fixture.root)
        _ = try await initial.open()
        let owner = try #require(try await ReferenceFixture.owners(initial).first)
        let source = try DocumentFixture.source(in: fixture)
        let existing = try await DocumentService(coordinator: initial).importFiles(
            [source], for: owner)[0].outcome.get()
        try await initial.close()
        let started = AsyncStream<Void>.makeStream()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let coordinator = LibraryCoordinator(
            root: fixture.root,
            dependencies: LibraryDependencies(importCheckpoint: { step in
                if step == .beforeRename {
                    started.continuation.yield(())
                    gate.wait()
                }
            }))
        _ = try await coordinator.open()
        let state = DocumentState(service: DocumentService(coordinator: coordinator))
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { !state.isLoading }
        let editing = makeEditing(coordinator, documents: state)
        state.importFiles([source], for: owner)
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(editing.isSaving)
        state.importFiles([source], for: owner)
        var navigated = false
        var cancelled = false
        editing.requestNavigation({ navigated = true }, onCancel: { cancelled = true })
        #expect(!navigated && cancelled)
        state.cancelImport()
        gate.signal()
        try await waitUntil { !state.isImporting }
        #expect(state.importResults.count == 1)
        if case .failure(let error) = state.importResults[0].outcome {
            #expect(error as? DocumentError == .fileImport(.cancelled))
        } else {
            Issue.record("Cancelled import must fail before commit")
        }
        #expect(state.records(for: owner) == [existing])
        #expect(try await coordinator.read(DocumentQueries.fetchAll) == [existing])
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func closedJobStateDisablesWritesAndRejectedSaveKeepsDraft() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        guard case .job(let jobID) = owners[1] else { throw NoteFixtureError() }
        let source = try DocumentFixture.source(in: fixture)
        let document = try await DocumentService(coordinator: coordinator).importFiles(
            [source], for: owners[1])[0].outcome.get()
        let state = DocumentState(service: DocumentService(coordinator: coordinator))
        let jobs = JobState(service: JobService(coordinator: coordinator))
        let observation = Task { await state.observe() }
        let jobObservation = Task { await jobs.observe() }
        defer { observation.cancel(); jobObservation.cancel() }
        try await waitUntil { !state.isLoading && !jobs.isLoading }
        state.open(document, for: owners[1])
        state.edit()
        state.draft?.notes = "Pending notes"
        #expect(state.canSave(jobs: jobs))
        var closure = JobTransitionDraft(stage: .completed)
        closure.outcome = "Finished"
        let closed = try await JobService(coordinator: coordinator).transition(
            jobID, using: closure)
        try await waitUntil { jobs.jobs.contains(closed) }
        #expect(!state.canWrite(owners[1], jobs: jobs))
        #expect(!state.canSave(jobs: jobs))
        #expect(state.canWrite(owners[0], jobs: jobs))
        #expect(!(await state.save()))
        #expect(state.draft?.notes == "Pending notes")
        #expect(state.selectedDocument == document)
        #expect(state.saveError != nil)
        observation.cancel()
        jobObservation.cancel()
        await observation.value
        await jobObservation.value
        try await coordinator.close()
    }

    private func makeEditing(_ coordinator: LibraryCoordinator, documents: DocumentState)
        -> WorkshopEditing
    {
        WorkshopEditing(
            watches: WatchState(service: WatchService(coordinator: coordinator)),
            calibers: CaliberState(service: CaliberService(coordinator: coordinator)),
            jobs: JobState(service: JobService(coordinator: coordinator)),
            notes: NoteState(service: NoteService(coordinator: coordinator)),
            references: ReferenceState(service: ReferenceService(coordinator: coordinator)),
            photos: PhotoState(service: PhotoService(coordinator: coordinator)),
            documents: documents,
            tasks: JobTaskState(service: JobTaskService(coordinator: coordinator)))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw DocumentObservationTimeout()
    }
}

nonisolated private struct DocumentObservationTimeout: Error {}

private final class DocumentBrowserSpy {
    var urls: [URL] = []
    var succeeds = true
    func open(_ url: URL) -> Bool { urls.append(url); return succeeds }
}
