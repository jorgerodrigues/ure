import Foundation
import GRDB
import Testing

@testable import Ure

struct ChildRemovalStateTests {
    @Test(.timeLimit(.minutes(1)))
    func failedRemovalKeepsTheViewerAndRemovalClosesItAndClearsThePin() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let job = try #require(try await coordinator.read(JobQueries.fetchAll).first)
        let source = try fixture.source(type: .png)
        let photo = try await MaterialFixture.file(source, for: owners[0], in: coordinator)
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
        let record = try #require(editing.material.records.first { $0.id == photo.id })
        editing.material.open(record, on: owners[0])
        bench.selectJob(job.id)
        bench.pin(photo.id)
        #expect(bench.reference?.id == photo.id)
        #expect(editing.material.isPresenting(on: owners[0]))
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql:
                    "CREATE TRIGGER failRemoval BEFORE DELETE ON libraryItem BEGIN SELECT RAISE(ABORT, 'injected'); END"
            )
        }
        #expect(await !editing.material.remove(record, on: owners[0], undoManager: nil).didSave)
        #expect(editing.material.presented?.itemID == photo.id)
        #expect(editing.material.error(for: owners[0]) != nil)
        #expect(bench.pinnedID == photo.id)
        try await coordinator.mutate { db, _, _ in try db.execute(sql: "DROP TRIGGER failRemoval") }
        #expect(await editing.material.remove(record, on: owners[0], undoManager: nil).didSave)
        #expect(editing.material.presented == nil && editing.material.error(for: owners[0]) == nil)
        try await SearchEditingFixture.waitUntil { bench.pinnedID == nil }
        #expect(bench.reference == nil && preferences.store.value.itemID == nil)
        observations.forEach { $0.cancel() }
        for observation in observations { await observation.value }
        let restarted = preferences.state(coordinator)
        restarted.apply(try await coordinator.read(BenchSnapshot.fetch))
        #expect(restarted.pinnedID == nil)
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
