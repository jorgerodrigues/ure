import CoreGraphics
import Foundation
import GRDB
import PDFKit
import Testing

@testable import Ure

struct BenchReferenceTests {
    @Test
    func jobPinsClearWhileWatchAndSharedCaliberPinsRemainApplicable() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let snapshot = try await coordinator.read(BenchSnapshot.fetch)
        let firstJob = try #require(snapshot.jobs.first)
        let caliber = try #require(snapshot.calibers.first)
        let items = try await makeLinks(coordinator, owners: owners)
        let preferences = try BenchTestPreferences(root: fixture.root)
        defer { preferences.remove() }
        let state = preferences.state(coordinator)
        var closure = JobTransitionDraft(stage: .completed)
        closure.outcome = "Inspection finished"
        _ = try await JobService(coordinator: coordinator).transition(firstJob.id, using: closure)
        let sameWatchJob = try await makeJob(coordinator, watchID: firstJob.watchID)
        var sharedWatch = WatchDraft()
        sharedWatch.name = "Second watch"
        sharedWatch.caliberID = caliber.id
        let secondWatch = try await WatchService(coordinator: coordinator).save(
            sharedWatch, editing: nil)
        let sharedJob = try await makeJob(coordinator, watchID: secondWatch.id)
        var unrelatedWatch = WatchDraft()
        unrelatedWatch.name = "Unrelated watch"
        let thirdWatch = try await WatchService(coordinator: coordinator).save(
            unrelatedWatch, editing: nil)
        let unrelatedJob = try await makeJob(coordinator, watchID: thirdWatch.id)
        state.apply(try await coordinator.read(BenchSnapshot.fetch))
        for item in items {
            state.selectJob(firstJob.id)
            state.pin(item.id)
            state.togglePane()
            #expect(state.reference?.item == item)
            state.selectJob(nil)
            #expect(state.reference?.item == item)
            state.selectJob(sameWatchJob.id)
            if item.jobID != nil {
                #expect(state.pinnedID == nil)
            } else {
                #expect(state.reference?.item == item)
            }
            state.selectJob(firstJob.id)
            state.pin(item.id)
            state.selectJob(sharedJob.id)
            if item.caliberID != nil {
                #expect(state.reference?.item == item)
            } else {
                #expect(state.pinnedID == nil)
            }
            state.selectJob(firstJob.id)
            state.pin(item.id)
            state.selectJob(unrelatedJob.id)
            #expect(state.pinnedID == nil)
        }
        state.pin(items[0].id)
        #expect(state.pinnedID == nil)
        try await coordinator.close()
    }

    @Test
    func restartRestoresOnlyExistingApplicablePreferencesAndIsolatesLibraries() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let items = try await makeLinks(coordinator, owners: owners)
        let snapshot = try await coordinator.read(BenchSnapshot.fetch)
        let job = try #require(snapshot.jobs.first)
        let preferences = try BenchTestPreferences(root: fixture.root)
        defer { preferences.remove() }
        let first = preferences.state(coordinator)
        first.apply(snapshot)
        first.selectJob(job.id)
        first.pin(items[0].id)
        first.togglePane()
        try await coordinator.close()
        let reopened = fixture.coordinator()
        _ = try await reopened.open()
        let restored = preferences.state(reopened)
        restored.apply(try await reopened.read(BenchSnapshot.fetch))
        #expect(restored.jobID == job.id && restored.reference?.item == items[0])
        #expect(!restored.showsPane)
        let separate = BenchPreferences(
            defaults: preferences.defaults, libraryRoot: fixture.root.appending(path: "other"))
        #expect(separate.value == BenchPreference())
        preferences.store.value = BenchPreference(jobID: job.id, itemID: UUID())
        let invalidItem = preferences.state(reopened)
        invalidItem.apply(snapshot)
        #expect(invalidItem.jobID == job.id && invalidItem.pinnedID == nil)
        #expect(preferences.store.value.itemID == nil)
        preferences.store.value = BenchPreference(jobID: UUID(), itemID: items[0].id)
        let invalidJob = preferences.state(reopened)
        invalidJob.apply(snapshot)
        #expect(invalidJob.jobID == nil && invalidJob.pinnedID == nil)
        #expect(preferences.store.value.jobID == nil)
        try await reopened.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func observedRemovalAndCaliberUnlinkClearPinWithoutChangingSavedContent() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let items = try await makeLinks(coordinator, owners: owners)
        let preferences = try BenchTestPreferences(root: fixture.root)
        defer { preferences.remove() }
        let state = preferences.state(coordinator)
        state.start()
        defer { state.stop() }
        try await waitUntil { !state.isLoading }
        let job = try #require(state.snapshot.jobs.first)
        state.selectJob(job.id)
        let caliberItem = try #require(items.first { $0.caliberID != nil })
        state.pin(caliberItem.id)
        let watch = try #require(state.snapshot.watches.first)
        var draft = WatchDraft(watch: watch)
        draft.caliberID = nil
        _ = try await WatchService(coordinator: coordinator).save(draft, editing: watch.id)
        try await waitUntil { state.pinnedID == nil }
        #expect(
            try await coordinator.read { try LibraryItemQueries.fetch(caliberItem.id, in: $0) }
                == caliberItem)
        let jobItem = try #require(items.first { $0.jobID != nil })
        state.pin(jobItem.id)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: "DELETE FROM libraryItem WHERE id = ?", arguments: [jobItem.id.uuidString])
        }
        try await waitUntil { state.pinnedID == nil }
        #expect(preferences.store.value.itemID == nil)
        #expect(state.pinMessage != nil)
        state.stop()
        try await coordinator.close()
    }

    @Test
    func missingOriginalClearsRestoredPinButKeepsRecordAndOriginalMetadata() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let source = try fixture.source(type: .png)
        let photo = try await PhotoService(coordinator: coordinator).importFiles(
            [source], for: owners[0])[0].outcome.get()
        let snapshot = try await coordinator.read(BenchSnapshot.fetch)
        let job = try #require(snapshot.jobs.first)
        let preferences = try BenchTestPreferences(root: fixture.root)
        defer { preferences.remove() }
        preferences.store.value = BenchPreference(jobID: job.id, itemID: photo.id)
        try FileManager.default.removeItem(
            at: try await coordinator.originalURL(for: photo.asset.id))
        let state = preferences.state(coordinator)
        state.apply(snapshot)
        await state.validatePin()
        #expect(state.pinnedID == nil && state.pinMessage != nil)
        #expect(preferences.store.value.itemID == nil)
        #expect(try await coordinator.read(PhotoQueries.fetchAll) == [photo])
        try await coordinator.close()
    }

    @Test
    func pinAndPaneActionsLeaveUnsavedNoteAndNavigationGuardIntact() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let items = try await makeLinks(coordinator, owners: owners)
        let preferences = try BenchTestPreferences(root: fixture.root)
        defer { preferences.remove() }
        let bench = preferences.state(coordinator)
        bench.apply(try await coordinator.read(BenchSnapshot.fetch))
        let job = try #require(bench.snapshot.jobs.first)
        bench.selectJob(job.id)
        let notes = NoteState(service: NoteService(coordinator: coordinator))
        let observation = Task { await notes.observe() }
        defer { observation.cancel() }
        try await waitUntil { !notes.isLoading }
        notes.create(for: .job(job.id))
        notes.draft?.title = "Unfinished bench note"
        let editing = WorkshopEditing(
            watches: WatchState(service: WatchService(coordinator: coordinator)),
            calibers: CaliberState(service: CaliberService(coordinator: coordinator)),
            jobs: JobState(service: JobService(coordinator: coordinator)), notes: notes,
            references: ReferenceState(service: ReferenceService(coordinator: coordinator)),
            photos: PhotoState(service: PhotoService(coordinator: coordinator)),
            documents: DocumentState(service: DocumentService(coordinator: coordinator)))
        bench.pin(items[0].id)
        bench.togglePane()
        #expect(notes.draft?.title == "Unfinished bench note")
        var navigated = false
        editing.requestNavigation { navigated = true }
        #expect(editing.showsUnsavedChanges && !navigated)
        editing.stay()
        #expect(notes.draft?.title == "Unfinished bench note")
        #expect(bench.reference?.item == items[0])
        #expect(try await coordinator.read(NoteQueries.fetchAll).isEmpty)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test
    func readerCanReadClosedJobFilesAndExportUnchangedBytesWithoutLibraryWrites() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let snapshot = try await coordinator.read(BenchSnapshot.fetch)
        let job = try #require(snapshot.jobs.first)
        let source = try DocumentFixture.source(in: fixture)
        let document = try await DocumentService(coordinator: coordinator).importFiles(
            [source], for: .job(job.id))[0].outcome.get()
        let photoSource = try fixture.source(type: .png)
        let photo = try await PhotoService(coordinator: coordinator).importFiles(
            [photoSource], for: owners[0])[0].outcome.get()
        var closure = JobTransitionDraft(stage: .completed)
        closure.outcome = "Closed for reference"
        _ = try await JobService(coordinator: coordinator).transition(job.id, using: closure)
        let before = try await coordinator.read(LibraryItemQueries.fetchAll)
        var reader = ReferenceReader(coordinator: coordinator)
        var browserCount = 0
        reader.openBrowser = { _ in
            browserCount += 1; return true
        }
        #expect(try await reader.document(for: document.asset.id).pageCount == 3)
        #expect(try await reader.image(for: photo.asset.id).width > 0)
        #expect(browserCount == 0)
        let destination = fixture.directory.appending(path: "reference-export.pdf")
        try await reader.export(document.asset.id, to: destination)
        #expect(try Data(contentsOf: destination) == Data(contentsOf: source))
        #expect(try await coordinator.read(LibraryItemQueries.fetchAll) == before)
        #expect(try await coordinator.read(JobQueries.fetchAll).first?.stage == .completed)
        try await coordinator.close()
    }

    @Test
    func paneLeavesSpaceForEditingAtTheMinimumWidth() {
        #expect(!BenchLayout.showsPane(availableWidth: 560, requested: true))
        #expect(!BenchLayout.showsPane(availableWidth: 880, requested: true))
        #expect(BenchLayout.showsPane(availableWidth: 881, requested: true))
        #expect(!BenchLayout.showsPane(availableWidth: 1000, requested: false))
    }

    private func makeLinks(_ coordinator: LibraryCoordinator, owners: [LibraryItemOwner])
        async throws -> [Ure.LibraryItem]
    {
        var items: [Ure.LibraryItem] = []
        for owner in owners {
            items.append(
                try await ReferenceService(coordinator: coordinator).save(
                    ReferenceFixture.draft, for: owner, editing: nil))
        }
        return items
    }

    private func makeJob(_ coordinator: LibraryCoordinator, watchID: UUID) async throws -> JobRecord
    {
        var draft = JobDraft()
        draft.title = "Next repair"
        return try await JobService(coordinator: coordinator).save(
            draft, for: watchID, editing: nil)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

private struct BenchTestPreferences {
    let defaults: UserDefaults
    let name = "UreBenchTests." + UUID().uuidString
    let store: BenchPreferences

    init(root: URL) throws {
        defaults = try #require(UserDefaults(suiteName: name))
        store = BenchPreferences(defaults: defaults, libraryRoot: root)
    }

    func remove() { defaults.removePersistentDomain(forName: name) }
    func state(_ coordinator: LibraryCoordinator) -> BenchReferenceState {
        BenchReferenceState(
            service: BenchReferenceService(coordinator: coordinator), preferences: store)
    }
}
