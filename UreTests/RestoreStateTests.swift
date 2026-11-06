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
        #expect(await state.session.watches.create())
        let watchID = try #require(state.session.watches.selectedID)
        let watchName = try #require(state.session.watches.facts(for: watchID)?.name)
        watchName.beginEditing()
        watchName.change(to: "Keep my unsaved watch", undoManager: nil)
        #expect(!state.canRestore)
        state.stage(from: fixture.package)
        await state.waitForCompletion()
        #expect(state.staged == nil)
        #expect(await state.session.watches.saveAllFacts())
        #expect(watchName.text == "Keep my unsaved watch")
        state.stage(from: fixture.package)
        await state.waitForCompletion()
        #expect(state.staged != nil)
        state.requestConfirmation()
        #expect(await state.session.calibers.create())
        let caliberID = try #require(state.session.calibers.selectedID)
        let name = try #require(state.session.calibers.facts(for: caliberID)?.name)
        name.beginEditing()
        name.change(to: "Keep my unsaved caliber", undoManager: nil)
        state.confirm()
        await state.waitForCompletion()
        #expect(name.text == "Keep my unsaved caliber")
        #expect(!state.isActivating)
        #expect(try fixture.pointer().generationID == seeded.library.generationID)
        #expect(await state.session.calibers.saveAllFacts())
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
        let reference = try await MaterialFixture.link(
            titled: "Technical sheet", for: owners[1], in: coordinator)
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
        #expect(state.session.checklist !== oldSession.checklist)
        #expect(state.session.parts !== oldSession.parts)
        #expect(state.session.material !== oldSession.material)
        #expect(state.session.search !== oldSession.search)
        #expect(state.session.jobList !== oldSession.jobList)
        #expect(state.session.partList !== oldSession.partList)
        #expect(state.session.bench !== oldSession.bench)
        #expect(!state.session.search.isPresented)
        #expect(state.session.navigation.selectedSection == .jobs)
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
