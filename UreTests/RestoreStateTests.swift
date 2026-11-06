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
        #expect(await state.session.watches.create().didSave)
        let watchID = try #require(state.session.watches.selectedID)
        let watchName = try #require(state.session.watches.facts(for: watchID)?.name)
        watchName.beginEditing()
        watchName.change(to: "Keep my unsaved watch", undoManager: nil)
        #expect(!state.canRestore)
        state.stage(from: fixture.package)
        await state.waitForCompletion()
        #expect(state.staged == nil)
        #expect(await state.session.editing.saveAllFields() == .saved)
        #expect(watchName.text == "Keep my unsaved watch")
        state.stage(from: fixture.package)
        await state.waitForCompletion()
        #expect(state.staged != nil)
        state.requestConfirmation()
        #expect(await state.session.calibers.create().didSave)
        let caliberID = try #require(state.session.calibers.selectedID)
        let name = try #require(state.session.calibers.facts(for: caliberID)?.name)
        name.beginEditing()
        name.change(to: "Keep my unsaved caliber", undoManager: nil)
        state.confirm()
        await state.waitForCompletion()
        #expect(name.text == "Keep my unsaved caliber")
        #expect(!state.isActivating)
        #expect(try fixture.pointer().generationID == seeded.library.generationID)
        #expect(await state.session.editing.saveAllFields() == .saved)
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

    @Test(.timeLimit(.minutes(1)))
    func settingsShowTheRestoredLibrarysCurrencyAndRates() async throws {
        let fixture = ActivationFixture()
        defer { fixture.files.remove() }
        let coordinator = LibraryCoordinator(root: fixture.files.root)
        try await Self.seedMoney(coordinator, package: fixture.package)
        let library = LibraryState(coordinator: coordinator)
        await library.open()
        let state = RestoreState(
            library: library, configuration: AppConfiguration(libraryRoot: fixture.files.root))
        // Only Settings is open, so nothing else observes the money settings.
        let observation = Task { await state.observeSettingsMoney() }
        try await waitUntil { state.settingsMoney?.settings.homeCurrency == "CHF" }
        #expect(state.settingsMoney?.rates.rates == ["USD": Self.amount("0.88")])
        state.stage(from: fixture.package)
        await state.waitForCompletion()
        state.requestConfirmation()
        state.confirm()
        await state.waitForCompletion()
        #expect(state.message?.contains("Library restored") == true)
        let money = try #require(state.settingsMoney)
        try await waitUntil { money.settings.homeCurrency == "GBP" }
        #expect(money.rates.rates == ["USD": Self.amount("0.79")])
        // Settings follows the restored library from now on, so a later change shows too.
        #expect(await money.setHomeCurrency("SEK"))
        try await waitUntil { money.home == "SEK" }
        #expect(money.rates.rates.isEmpty)
        observation.cancel()
        await observation.value
        try await library.coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func settingsTakeNoMoneyEditsWhileARestoreReplacesTheLibrary() async throws {
        let fixture = ActivationFixture()
        defer { fixture.files.remove() }
        let coordinator = LibraryCoordinator(root: fixture.files.root)
        try await Self.seedMoney(coordinator, package: fixture.package)
        let library = LibraryState(coordinator: coordinator)
        await library.open()
        let state = RestoreState(
            library: library, configuration: AppConfiguration(libraryRoot: fixture.files.root))
        state.stage(from: fixture.package)
        await state.waitForCompletion()
        let replaced = try #require(state.settingsMoney)
        state.requestConfirmation()
        state.confirm()
        // While the restore runs, Settings has no money settings to edit, so no edit goes to the
        // library that is being replaced.
        #expect(state.isActivating)
        #expect(state.settingsMoney == nil)
        await state.waitForCompletion()
        // Afterwards Settings edits the restored library, and what you set there is kept.
        let restored = try #require(state.settingsMoney)
        #expect(restored !== replaced)
        #expect(await restored.setHomeCurrency("SEK"))
        #expect(try await library.coordinator.read { try MoneyQueries.homeCurrency($0) } == "SEK")
        try await library.coordinator.close()
    }

    // A backup whose home currency is GBP with a USD rate, and a current library that has since
    // changed to CHF with another USD rate.
    private static func seedMoney(_ coordinator: LibraryCoordinator, package: URL) async throws {
        _ = try await coordinator.open()
        let money = MoneyService(
            coordinator: coordinator, region: "DKK", locale: Locale(identifier: "en_US_POSIX"))
        try await money.setHomeCurrency("GBP")
        try await money.setRate("0.79", for: "USD")
        _ = try await coordinator.exportBackup(to: package, applicationVersion: "fixture")
        try await money.setHomeCurrency("CHF")
        try await money.setRate("0.88", for: "USD")
    }

    private static func amount(_ text: String) -> Decimal {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) ?? .nan
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RestoreWaitTimeout()
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

nonisolated private struct RestoreWaitTimeout: Error {}
