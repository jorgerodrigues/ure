import Foundation
import Synchronization
import Testing

@testable import Ure

struct RestoreStateTests {
    @Test
    func cancellationAfterReviewKeepsCurrentPointerAndRemovesOnlyCandidate() async throws {
        let fixture = ActivationFixture()
        defer { fixture.files.remove() }
        let coordinator = LibraryCoordinator(root: fixture.files.root)
        let seeded = try await fixture.seed(coordinator)
        let library = LibraryState(coordinator: coordinator)
        await library.open()
        let state = RestoreState(
            library: library, configuration: AppConfiguration(libraryRoot: fixture.files.root))
        state.stage(from: fixture.package)
        await state.waitForCompletion()
        let staged = try #require(state.staged)
        #expect(staged.summary.counts["watch"] == 1)
        #expect(state.message == nil)
        state.requestConfirmation()
        #expect(state.showsConfirmation)
        state.cancelConfirmation()
        state.confirm()
        #expect(!state.isActivating)
        #expect(try fixture.pointer().generationID == seeded.library.generationID)
        state.cancel()
        await state.waitForCompletion()
        #expect(state.staged == nil)
        #expect(!state.isBusy)
        #expect(state.message?.contains("cancelled") == true)
        #expect(try fixture.pointer().generationID == seeded.library.generationID)
        #expect(
            !FileManager.default.fileExists(
                atPath: LibraryFiles.generation(staged.library.generationID, in: fixture.files.root)
                    .path))
        #expect(
            try await coordinator.read(WatchQueries.fetchAll).first?.name == "Newer current watch")
        try await coordinator.close()
    }

    @Test
    func draftsBeforeSelectionAndAfterReviewRejectActivationAndRemainEditable() async throws {
        let fixture = ActivationFixture()
        defer { fixture.files.remove() }
        let coordinator = LibraryCoordinator(root: fixture.files.root)
        let seeded = try await fixture.seed(coordinator)
        let library = LibraryState(coordinator: coordinator)
        await library.open()
        let state = RestoreState(
            library: library, configuration: AppConfiguration(libraryRoot: fixture.files.root))
        state.session.watches.create()
        state.session.watches.draft?.name = "Keep my unsaved watch"
        #expect(!state.canRestore)
        state.stage(from: fixture.package)
        await state.waitForCompletion()
        #expect(state.staged == nil)
        state.session.watches.cancel()
        state.stage(from: fixture.package)
        await state.waitForCompletion()
        #expect(state.staged != nil)
        state.requestConfirmation()
        state.session.calibers.create()
        state.session.calibers.draft?.designation = "Keep my unsaved caliber"
        state.confirm()
        await state.waitForCompletion()
        #expect(state.session.calibers.draft?.designation == "Keep my unsaved caliber")
        #expect(!state.isActivating)
        #expect(try fixture.pointer().generationID == seeded.library.generationID)
        state.session.calibers.cancel()
        state.cancel()
        await state.waitForCompletion()
        try await coordinator.close()
    }

    @Test
    func quittingAfterReviewDiscardsTheRegisteredCopyAndKeepsCurrentLibrary() async throws {
        let fixture = ActivationFixture()
        defer { fixture.files.remove() }
        let coordinator = LibraryCoordinator(root: fixture.files.root)
        let seeded = try await fixture.seed(coordinator)
        let library = LibraryState(coordinator: coordinator)
        await library.open()
        let state = RestoreState(
            library: library, configuration: AppConfiguration(libraryRoot: fixture.files.root))
        state.stage(from: fixture.package)
        await state.waitForCompletion()
        let staged = try #require(state.staged)
        #expect(await state.discardForTermination())
        #expect(state.staged == nil)
        #expect(try fixture.pointer().generationID == seeded.library.generationID)
        #expect(
            !FileManager.default.fileExists(
                atPath: LibraryFiles.generation(staged.library.generationID, in: fixture.files.root)
                    .path))
        try await coordinator.close()
    }

    @Test
    func failedRecoveryKeepsOneReviewCopyForRetryOrCancellation() async throws {
        let fixture = ActivationFixture()
        defer { fixture.files.remove() }
        let lowSpace = Mutex(false)
        let coordinator = LibraryCoordinator(
            root: fixture.files.root,
            dependencies: LibraryDependencies(restoreAvailableCapacity: { _ in
                lowSpace.withLock { $0 } ? 0 : Int64.max
            }))
        let seeded = try await fixture.seed(coordinator)
        let library = LibraryState(coordinator: coordinator)
        await library.open()
        let state = RestoreState(
            library: library, configuration: AppConfiguration(libraryRoot: fixture.files.root))
        state.stage(from: fixture.package)
        await state.waitForCompletion()
        let staged = try #require(state.staged)
        lowSpace.withLock { $0 = true }
        for _ in 0..<2 {
            state.requestConfirmation()
            state.confirm()
            await state.waitForCompletion()
            #expect(state.staged == staged)
            #expect(state.canRestore)
            #expect(state.errorMessage?.contains("free disk space") == true)
            #expect(try fixture.pointer().generationID == seeded.library.generationID)
            #expect(
                try FileManager.default.contentsOfDirectory(
                    atPath: fixture.files.root.appending(path: "generations").path
                ).count == 2)
        }
        #expect(await state.discardForTermination())
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.files.root.appending(path: "generations").path
            ).count == 1)
        try await library.coordinator.close()
    }

    @Test
    func explicitConfirmationReplacesAllFeatureStateAndClearsOpenReferenceState() async throws {
        let fixture = ActivationFixture()
        defer { fixture.files.remove() }
        let coordinator = LibraryCoordinator(root: fixture.files.root)
        _ = try await fixture.seed(coordinator)
        let library = LibraryState(coordinator: coordinator)
        await library.open()
        let state = RestoreState(
            library: library, configuration: AppConfiguration(libraryRoot: fixture.files.root))
        let oldSession = state.session
        let owners = try await ReferenceFixture.owners(coordinator)
        let reference = try await ReferenceService(coordinator: coordinator).save(
            ReferenceFixture.draft, for: owners[1], editing: nil)
        let snapshot = try await coordinator.read(BenchSnapshot.fetch)
        oldSession.bench.apply(snapshot)
        oldSession.bench.selectJob(snapshot.jobs.first?.id)
        oldSession.bench.pin(reference.id)
        #expect(oldSession.bench.reference != nil)
        oldSession.search.present()
        oldSession.navigation.selection = .calibers
        state.stage(from: fixture.package)
        await state.waitForCompletion()
        let staged = try #require(state.staged)
        state.confirm()
        #expect(!state.isActivating)
        state.requestConfirmation()
        state.showsConfirmation = false
        state.confirm()
        state.confirm()
        #expect(state.isActivating)
        #expect(oldSession.bench.reference == nil)
        await state.waitForCompletion()
        #expect(state.session.id != oldSession.id)
        #expect(state.session.editing !== oldSession.editing)
        #expect(state.session.watches !== oldSession.watches)
        #expect(state.session.jobs !== oldSession.jobs)
        #expect(state.session.calibers !== oldSession.calibers)
        #expect(state.session.notes !== oldSession.notes)
        #expect(state.session.tasks !== oldSession.tasks)
        #expect(state.session.parts !== oldSession.parts)
        #expect(state.session.photos !== oldSession.photos)
        #expect(state.session.documents !== oldSession.documents)
        #expect(state.session.references !== oldSession.references)
        #expect(state.session.search !== oldSession.search)
        #expect(state.session.workshop !== oldSession.workshop)
        #expect(state.session.partsOverview !== oldSession.partsOverview)
        #expect(state.session.bench !== oldSession.bench)
        #expect(!state.session.search.isPresented)
        #expect(state.session.navigation.selectedSection == .workshop)
        #expect(state.recoveryDirectory != nil)
        #expect(state.errorMessage == nil)
        #expect(state.message?.contains("Library restored") == true)
        #expect(state.staged == nil)
        #expect(library.phase == .ready(staged.library))
        #expect(state.backup.summary?.counts["watch"] == 1)
        #expect(
            try await library.coordinator.read(WatchQueries.fetchAll).first?.name == "Backup watch")
        try await library.coordinator.close()
    }
}
