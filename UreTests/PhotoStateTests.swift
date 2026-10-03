import Foundation
import Testing

@testable import Ure

struct PhotoStateTests {
    @Test(.timeLimit(.minutes(1)))
    func changingStageKeepsAdjacentFilteredPhotosNavigable() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        let source = try fixture.source(type: .png)
        let service = PhotoService(coordinator: coordinator)
        for _ in 0..<3 {
            let photo = try await service.importFiles([source], for: owner)[0].outcome.get()
            var draft = PhotoDraft(item: photo.item)
            draft.stage = .before
            _ = try await service.save(draft, for: owner, editing: photo.id)
        }
        let state = PhotoState(service: service)
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { !state.isLoading }
        state.stageFilter = .before
        let records = state.records(for: owner)
        state.open(records[1], for: owner)
        state.edit()
        state.draft?.stage = .after
        #expect(await state.save())
        #expect(state.records(for: owner).count == 2)
        #expect(state.canMove(by: -1) && state.canMove(by: 1))
        state.moveSelection(by: 1)
        #expect(state.selectedID == records[2].id)
        state.moveSelection(by: -1)
        #expect(state.selectedID == records[0].id)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func stageFiltersAndKeyboardSelectionStayInScopeAndDraftUsesSharedGuard() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let source = try fixture.source(type: .png)
        let service = PhotoService(coordinator: coordinator)
        for owner in owners {
            for stage in PhotoStage.allCases {
                let photo = try await service.importFiles([source], for: owner)[0].outcome.get()
                var draft = PhotoDraft(item: photo.item)
                draft.stage = stage
                _ = try await service.save(draft, for: owner, editing: photo.id)
            }
        }
        let state = PhotoState(service: service)
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { !state.isLoading }
        for owner in owners {
            state.stageFilter = nil
            #expect(state.records(for: owner).count == 4)
            for stage in PhotoStage.allCases {
                state.stageFilter = stage
                let records = state.records(for: owner)
                #expect(records.count == 1)
                #expect(
                    records.allSatisfy { $0.item.photoStage == stage && $0.item.belongs(to: owner) }
                )
            }
        }
        state.stageFilter = nil
        let records = state.records(for: owners[0])
        state.open(records[0], for: owners[0])
        state.moveSelection(by: -1)
        #expect(state.selectedID == records[0].id)
        state.moveSelection(by: 1)
        #expect(state.selectedID == records[1].id)
        state.open(records[0], for: owners[2])
        #expect(state.owner == owners[0])
        let editing = makeEditing(coordinator, photos: state)
        state.edit()
        state.draft?.caption = "Keep this caption"
        var navigated = false
        editing.requestNavigation { navigated = true }
        #expect(!navigated)
        #expect(editing.unsavedChangesTitle == "Save changes to this photo?")
        editing.stay()
        #expect(state.draft?.caption == "Keep this caption")
        state.draft?.title = " "
        editing.requestNavigation { navigated = true }
        await editing.saveAndContinue()
        #expect(!navigated)
        #expect(state.saveError != nil)
        #expect(state.draft?.caption == "Keep this caption")
        state.draft?.title = "Saved title"
        editing.requestNavigation { navigated = true }
        await editing.saveAndContinue()
        #expect(navigated)
        #expect(state.selectedPhoto?.item.caption == "Keep this caption")
        state.edit()
        state.draft?.caption = "Discard this"
        editing.requestNavigation {}
        editing.discardAndContinue()
        #expect(state.selectedPhoto?.item.caption == "Keep this caption")
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingImportBlocksDuplicatesAndNavigationAndCancellationKeepsExistingPhotos() async throws
    {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let initial = LibraryCoordinator(root: fixture.root)
        _ = try await initial.open()
        let owner = try #require(try await ReferenceFixture.owners(initial).first)
        let source = try fixture.source(type: .png)
        let existing = try await PhotoService(coordinator: initial).importFiles(
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
        let state = PhotoState(service: PhotoService(coordinator: coordinator))
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { !state.isLoading }
        let editing = makeEditing(coordinator, photos: state)
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
            #expect(error as? PhotoError == .fileImport(.cancelled))
        } else {
            Issue.record("Cancelled import must fail before commit")
        }
        #expect(state.records(for: owner) == [existing])
        #expect(try await coordinator.read(PhotoQueries.fetchAll) == [existing])
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
        let source = try fixture.source(type: .jpeg)
        let photo = try await PhotoService(coordinator: coordinator).importFiles(
            [source], for: owners[1])[0].outcome.get()
        let state = PhotoState(service: PhotoService(coordinator: coordinator))
        let jobs = JobState(service: JobService(coordinator: coordinator))
        let observation = Task { await state.observe() }
        let jobObservation = Task { await jobs.observe() }
        defer { observation.cancel(); jobObservation.cancel() }
        try await waitUntil { !state.isLoading && !jobs.isLoading }
        state.open(photo, for: owners[1])
        state.edit()
        state.draft?.caption = "Pending caption"
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
        #expect(state.draft?.caption == "Pending caption")
        #expect(state.selectedPhoto == photo)
        #expect(state.saveError != nil)
        observation.cancel()
        jobObservation.cancel()
        await observation.value
        await jobObservation.value
        try await coordinator.close()
    }

    private func makeEditing(_ coordinator: LibraryCoordinator, photos: PhotoState)
        -> WorkshopEditing
    {
        WorkshopEditing(
            watches: WatchState(service: WatchService(coordinator: coordinator)),
            calibers: CaliberState(service: CaliberService(coordinator: coordinator)),
            jobs: JobState(service: JobService(coordinator: coordinator)),
            notes: NoteState(service: NoteService(coordinator: coordinator)),
            references: ReferenceState(service: ReferenceService(coordinator: coordinator)),
            photos: photos,
            documents: DocumentState(service: DocumentService(coordinator: coordinator)),
            tasks: JobTaskState(service: JobTaskService(coordinator: coordinator)),
            parts: PartState(service: PartService(coordinator: coordinator)))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PhotoObservationTimeout()
    }
}

nonisolated private struct PhotoObservationTimeout: Error {}
