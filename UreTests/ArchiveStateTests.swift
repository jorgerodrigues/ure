import Foundation
import GRDB
import Testing

@testable import Ure

struct ArchiveStateTests {
    @Test(.timeLimit(.minutes(1)))
    func listsKeepArchivedOwnersLoadedAndArchiveNavigationProtectsDrafts() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        _ = try await NoteFixture.owners(coordinator)
        let watch = try #require(try await coordinator.read(WatchQueries.fetchAll).first)
        let caliber = try #require(try await coordinator.read(CaliberQueries.fetchAll).first)
        let job = try #require(try await coordinator.read(JobQueries.fetchAll).first)
        var closure = JobTransitionDraft(stage: .cancelled)
        closure.cancellationReason = "Retain for later"
        _ = try await JobService(coordinator: coordinator).transition(job.id, using: closure)
        _ = try await ArchiveService(coordinator: coordinator).setWatch(watch.id, archived: true)
        _ = try await ArchiveService(coordinator: coordinator).setCaliber(
            caliber.id, archived: true)
        let editing = SearchEditingFixture.make(coordinator)
        let observations = SearchEditingFixture.observe(editing)
        defer { observations.forEach { $0.cancel() } }
        try await SearchEditingFixture.waitUntil { SearchEditingFixture.loaded(editing) }
        #expect(
            editing.watches.filteredWatches.isEmpty && editing.calibers.filteredCalibers.isEmpty)
        #expect(editing.watches.watches.count == 1 && editing.calibers.calibers.count == 1)
        #expect(editing.archive.records(editing: editing).count == 3)
        editing.archive.open(.job(job.id), editing: editing)
        #expect(editing.jobs.selectedID == job.id && editing.watches.selectedID == watch.id)
        let revision = editing.archive.navigationRevision
        editing.archive.open(.job(job.id), editing: editing)
        #expect(editing.archive.navigationRevision == revision + 1)
        #expect(!editing.canWrite(LibraryItemOwner.watch(watch.id)))
        #expect(!editing.canWrite(LibraryItemOwner.caliber(caliber.id)))
        editing.archive.open(.caliber(caliber.id), editing: editing)
        #expect(editing.archive.isShowingCaliber(editing: editing))
        #expect(editing.jobs.selectedID == nil && editing.calibers.selectedID == caliber.id)
        #expect(await editing.calibers.toggleArchive())
        try await SearchEditingFixture.waitUntil { editing.calibers.filteredCalibers.count == 1 }
        #expect(editing.canWrite(LibraryItemOwner.caliber(caliber.id)))
        editing.calibers.edit()
        editing.calibers.draft?.designation = "Keep caliber correction"
        editing.archive.open(.watch(watch.id), editing: editing)
        #expect(
            editing.showsUnsavedChanges && editing.archive.selectedTarget == .caliber(caliber.id))
        editing.stay()
        #expect(editing.calibers.draft?.designation == "Keep caliber correction")
        editing.archive.open(.watch(watch.id), editing: editing)
        await editing.saveAndContinue()
        #expect(editing.archive.selectedTarget == .watch(watch.id))
        #expect(editing.calibers.draft == nil)
        #expect(await editing.watches.toggleArchive())
        try await SearchEditingFixture.waitUntil { editing.watches.filteredWatches.count == 1 }
        editing.archive.searchText = job.title.uppercased()
        #expect(editing.archive.records(editing: editing).map(\.id) == [.job(job.id)])
        observations.forEach { $0.cancel() }
        for observation in observations { await observation.value }
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func removalFailureKeepsSelectionAndSuccessfulConfirmationClearsItAndThePin() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let job = try #require(try await coordinator.read(JobQueries.fetchAll).first)
        let source = try fixture.source(type: .png)
        let photo = try #require(
            await PhotoService(coordinator: coordinator).importFiles([source], for: owners[0]).first
        ).outcome.get()
        let editing = SearchEditingFixture.make(coordinator)
        let preferences = try ArchiveBenchPreferences(root: fixture.root)
        defer { preferences.remove() }
        let bench = preferences.state(coordinator)
        let observations = SearchEditingFixture.observe(editing) + [Task { await bench.observe() }]
        defer { observations.forEach { $0.cancel() } }
        try await SearchEditingFixture.waitUntil {
            SearchEditingFixture.loaded(editing) && !bench.isLoading
        }
        editing.watches.select(job.watchID)
        editing.jobs.open(job)
        editing.photos.open(photo, for: owners[0])
        bench.selectJob(job.id)
        bench.pin(photo.id)
        #expect(bench.reference?.id == photo.id)
        #expect(await editing.photos.remove() == false)
        editing.photos.requestRemoval()
        #expect(editing.photos.showsRemovalConfirmation)
        editing.photos.showsRemovalConfirmation = false
        #expect(editing.photos.selectedID == photo.id)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql:
                    "CREATE TRIGGER failRemoval BEFORE DELETE ON libraryItem BEGIN SELECT RAISE(ABORT, 'injected'); END"
            )
        }
        editing.photos.requestRemoval()
        #expect(await editing.photos.remove() == false)
        #expect(editing.photos.selectedID == photo.id && editing.photos.saveError != nil)
        #expect(bench.pinnedID == photo.id)
        try await coordinator.mutate { db, _, _ in try db.execute(sql: "DROP TRIGGER failRemoval") }
        editing.photos.requestRemoval()
        #expect(await editing.photos.remove())
        #expect(editing.photos.selectedID == nil && editing.photos.owner == nil)
        try await SearchEditingFixture.waitUntil { bench.pinnedID == nil }
        #expect(bench.reference == nil && preferences.store.value.itemID == nil)
        observations.forEach { $0.cancel() }
        for observation in observations { await observation.value }
        let restarted = preferences.state(coordinator)
        restarted.apply(try await coordinator.read(BenchSnapshot.fetch))
        #expect(restarted.pinnedID == nil)
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func taskConfirmationListsPartsAndRejectsChangedLinksBeforeRemovingAnything() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let part = try await PartService(coordinator: coordinator).save(
            PartFixture.draft(), for: job.id, editing: nil)
        var draft = JobTaskFixture.draft(.done)
        draft.partIDs = [part.id]
        let task = try await JobTaskService(coordinator: coordinator).save(
            draft, for: job.id, editing: nil)
        let editing = SearchEditingFixture.make(coordinator)
        let observations = SearchEditingFixture.observe(editing)
        defer { observations.forEach { $0.cancel() } }
        try await SearchEditingFixture.waitUntil { SearchEditingFixture.loaded(editing) }
        editing.tasks.open(task, for: job.id)
        editing.tasks.requestRemoval()
        #expect(editing.tasks.removalMessage.contains(part.record.description))
        draft.partIDs = []
        _ = try await JobTaskService(coordinator: coordinator).save(
            draft, for: job.id, editing: task.id)
        #expect(await editing.tasks.remove() == false)
        #expect(editing.tasks.saveError != nil && editing.tasks.selectedID == task.id)
        try await SearchEditingFixture.waitUntil { editing.tasks.linkedParts(for: task.id).isEmpty }
        editing.tasks.requestRemoval()
        #expect(await editing.tasks.remove())
        #expect(editing.tasks.selectedID == nil && editing.tasks.jobID == nil)
        #expect(try await coordinator.read { try PartQueries.fetch(part.id, in: $0) } == part)
        observations.forEach { $0.cancel() }
        for observation in observations { await observation.value }
        try await coordinator.close()
    }
}

private struct ArchiveBenchPreferences {
    let defaults: UserDefaults
    let name = "UreArchiveTests." + UUID().uuidString
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
