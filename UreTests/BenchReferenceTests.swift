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
        _ = try await JobService(coordinator: coordinator).setStage(firstJob.id, to: .done)
        let sameWatchJob = try await makeJob(coordinator, watchID: try #require(firstJob.watchID))
        let secondWatch = try await WatchService(coordinator: coordinator).make(
            "Second watch", caliberID: caliber.id)
        let sharedJob = try await makeJob(coordinator, watchID: secondWatch.id)
        let thirdWatch = try await WatchService(coordinator: coordinator).make("Unrelated watch")
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
        _ = try await WatchService(coordinator: coordinator).update(watch.id, .caliber(nil))
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
        let photo = try await MaterialFixture.file(source, for: owners[0], in: coordinator)
        let snapshot = try await coordinator.read(BenchSnapshot.fetch)
        let job = try #require(snapshot.jobs.first)
        let preferences = try BenchTestPreferences(root: fixture.root)
        defer { preferences.remove() }
        preferences.store.value = BenchPreference(jobID: job.id, itemID: photo.id)
        try FileManager.default.removeItem(
            at: try await coordinator.originalURL(for: try #require(photo.asset).id))
        let state = preferences.state(coordinator)
        state.apply(snapshot)
        await state.validatePin()
        #expect(state.pinnedID == nil && state.pinMessage != nil)
        #expect(preferences.store.value.itemID == nil)
        #expect(try await coordinator.read(MaterialQueries.fetchAll) == [photo])
        try await coordinator.close()
    }

    @Test
    func pinAndPaneActionsLeaveTypingInPlaceAndLeavingSavesIt() async throws {
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
        let editing = EditingFixture.make(coordinator)
        let observation = Task { await editing.jobs.observe() }
        defer { observation.cancel() }
        let partObservation = Task { await editing.parts.observe() }
        defer { partObservation.cancel() }
        try await waitUntil { !editing.jobs.isLoading && !editing.parts.isLoading }
        editing.jobs.open(try #require(editing.jobs.jobs.first { $0.id == job.id }))
        let part = try #require(await editing.parts.add(named: "Bench part", to: job.id)?.part)
        let facts = try #require(editing.parts.facts(for: part.id))
        facts.name.beginEditing()
        facts.name.change(to: "Unfinished bench part", undoManager: nil)
        bench.pin(items[0].id)
        bench.togglePane()
        #expect(facts.name.text == "Unfinished bench part" && facts.name.isEditing)
        var navigated = false
        editing.requestNavigation { navigated = true }
        #expect(navigated)
        try await waitUntil { !facts.name.hasUnsavedChanges }
        #expect(
            try await coordinator.read { try PartQueries.fetch(part.id, in: $0) }?.name
                == "Unfinished bench part")
        #expect(bench.reference?.item == items[0])
        #expect(try await coordinator.read(LibraryItemQueries.fetchAll).count == items.count)
        observation.cancel()
        partObservation.cancel()
        await observation.value
        await partObservation.value
        try await coordinator.close()
    }

    @Test
    func readerCanReadDoneJobFilesAndExportUnchangedBytesWithoutLibraryWrites() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let snapshot = try await coordinator.read(BenchSnapshot.fetch)
        let job = try #require(snapshot.jobs.first)
        let source = try DocumentFixture.source(in: fixture)
        let document = try #require(
            try await MaterialFixture.file(source, for: .job(job.id), in: coordinator).asset)
        let photoSource = try fixture.source(type: .png)
        let photo = try #require(
            try await MaterialFixture.file(photoSource, for: owners[0], in: coordinator).asset)
        _ = try await JobService(coordinator: coordinator).setStage(job.id, to: .done)
        let before = try await coordinator.read(LibraryItemQueries.fetchAll)
        let reader = ReferenceReader(coordinator: coordinator)
        #expect(try await reader.document(for: document.id).pageCount == 3)
        #expect(try await reader.image(for: photo.id).width > 0)
        let destination = fixture.directory.appending(path: "reference-export.pdf")
        try await reader.export(document.id, to: destination)
        #expect(try Data(contentsOf: destination) == Data(contentsOf: source))
        #expect(try await coordinator.read(LibraryItemQueries.fetchAll) == before)
        #expect(try await coordinator.read(JobQueries.fetchAll).first?.stage == .done)
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
                try await MaterialFixture.link(
                    titled: "Technical sheet", for: owner, in: coordinator))
        }
        return items
    }

    private func makeJob(_ coordinator: LibraryCoordinator, watchID: UUID) async throws -> JobRecord
    {
        return try await JobService(coordinator: coordinator).start(
            for: watchID, title: "Next repair")
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
