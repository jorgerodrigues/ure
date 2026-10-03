import Foundation
import GRDB
import Synchronization
import Testing

@testable import Ure

nonisolated struct RestoreActivationTests {
    @Test
    func activationReplacesRecordsAndRetainsCompleteRecoveryAndOriginalGenerations() async throws {
        let fixture = ActivationFixture()
        defer { fixture.files.remove() }
        let coordinator = LibraryCoordinator(root: fixture.files.root)
        let seeded = try await fixture.seed(coordinator)
        let staged = try await coordinator.stageRestore(from: fixture.package)
        let observation = try await coordinator.watchValues()
        let observer = Task {
            do {
                for try await _ in observation {
                    if Task.isCancelled { return }
                }
            } catch {}
        }
        defer { observer.cancel() }
        let result = try await coordinator.activateRestore(staged)
        #expect(result.outcome == .restored)
        #expect(result.library == staged.library)
        #expect(try fixture.pointer().generationID == staged.library.generationID)
        #expect(
            try await result.coordinator.read(WatchQueries.fetchAll).first?.name == "Backup watch")
        let recovery = try #require(result.recovery)
        let reader = try RestoreDatabase.open(in: recovery.directory, readonly: true)
        #expect(try await reader.read(WatchQueries.fetchAll).first?.name == "Newer current watch")
        #expect(try await reader.read(FileAssetQueries.fetchAll) == [seeded.asset])
        try reader.close()
        let original = "originals/\(seeded.asset.storageKey)"
        #expect(try Data(contentsOf: recovery.directory.appending(path: original)) == seeded.bytes)
        #expect(
            try Data(
                contentsOf: LibraryFiles.generation(
                    seeded.library.generationID, in: fixture.files.root
                ).appending(path: original)) == seeded.bytes)
        #expect(
            try Data(
                contentsOf: LibraryFiles.generation(
                    staged.library.generationID, in: fixture.files.root
                ).appending(path: original)) == seeded.bytes)
        await #expect(throws: LibraryError.notOpen) { _ = try await coordinator.open() }
        await #expect(throws: LibraryError.notOpen) {
            _ = try await coordinator.read(WatchQueries.fetchAll)
        }
        await #expect(throws: LibraryError.notOpen) {
            _ = try await WatchService(coordinator: coordinator).save(
                ActivationFixture.draft("Stale"), editing: nil)
        }
        await #expect(throws: LibraryError.notOpen) {
            _ = try await coordinator.importOriginal(
                from: fixture.files.source(type: .pdf), maximumByteCount: 1_000_000)
        }
        try await result.coordinator.close()
        let restarted = LibraryCoordinator(root: fixture.files.root)
        #expect(try await restarted.open() == staged.library)
        try await restarted.close()
    }

    @Test(arguments: [
        RestoreActivationCheckpoint.beforeRecovery, .afterRecovery, .beforeSwitch, .afterSwitch,
        .beforeFirstOpen, .afterFirstOpen,
    ])
    func injectedFailureKeepsOrRollsBackToCurrentLibrary(step: RestoreActivationCheckpoint)
        async throws
    {
        let fixture = ActivationFixture()
        defer { fixture.files.remove() }
        let coordinator = LibraryCoordinator(
            root: fixture.files.root,
            dependencies: LibraryDependencies(activationCheckpoint: { checkpoint in
                if checkpoint == step { throw CocoaError(.fileWriteOutOfSpace) }
            }))
        let seeded = try await fixture.seed(coordinator)
        let staged = try await coordinator.stageRestore(from: fixture.package)
        let result = try await coordinator.activateRestore(staged)
        #expect(result.outcome == .keptCurrent)
        #expect(result.library == seeded.library)
        #expect(try fixture.pointer().generationID == seeded.library.generationID)
        #expect(
            try await result.coordinator.read(WatchQueries.fetchAll).first?.name
                == "Newer current watch")
        if step != .beforeRecovery { #expect(result.recovery != nil) }
        #expect(
            FileManager.default.fileExists(
                atPath: LibraryFiles.generation(staged.library.generationID, in: fixture.files.root)
                    .path))
        switch step {
        case .beforeRecovery, .afterRecovery, .beforeSwitch:
            #expect(result.candidate == staged)
            try await result.coordinator.discardRestore(staged)
            #expect(
                !FileManager.default.fileExists(
                    atPath: LibraryFiles.generation(
                        staged.library.generationID, in: fixture.files.root
                    ).path))
        default:
            #expect(result.candidate == nil)
        }
        try await result.coordinator.close()
        let restarted = LibraryCoordinator(root: fixture.files.root)
        #expect(try await restarted.open() == seeded.library)
        try await restarted.close()
    }

    @Test(arguments: [
        RestoreActivationCheckpoint.beforeSwitch, .afterSwitch, .beforeFirstOpen, .afterFirstOpen,
    ])
    func restartFromPointerAtInterruptionOpensOneCompleteGeneration(
        step: RestoreActivationCheckpoint
    ) async throws {
        let fixture = ActivationFixture()
        defer { fixture.files.remove() }
        let interruptedPointer = Mutex<Data?>(nil)
        let pointerURL = fixture.files.root.appending(path: "active-library.json")
        let coordinator = LibraryCoordinator(
            root: fixture.files.root,
            dependencies: LibraryDependencies(activationCheckpoint: { checkpoint in
                if checkpoint == step {
                    interruptedPointer.withLock { $0 = try? Data(contentsOf: pointerURL) }
                }
            }))
        let seeded = try await fixture.seed(coordinator)
        let staged = try await coordinator.stageRestore(from: fixture.package)
        let result = try await coordinator.activateRestore(staged)
        try await result.coordinator.close()
        try #require(interruptedPointer.withLock { $0 }).write(to: pointerURL, options: .atomic)
        let restarted = LibraryCoordinator(root: fixture.files.root)
        let opened = try await restarted.open()
        let expected = step == .beforeSwitch ? seeded.library : staged.library
        #expect(opened == expected)
        #expect(
            try Data(contentsOf: await restarted.originalURL(for: seeded.asset.id)) == seeded.bytes)
        let expectedName = step == .beforeSwitch ? "Newer current watch" : "Backup watch"
        #expect(try await restarted.read(WatchQueries.fetchAll).first?.name == expectedName)
        try await restarted.close()
    }

    @Test(arguments: [false, true])
    func failedFirstOpenRollsBackOrShowsRecoveryWithoutAnEmptyReplacement(rollbackFails: Bool)
        async throws
    {
        let fixture = ActivationFixture()
        defer { fixture.files.remove() }
        let stagedDirectory = Mutex<URL?>(nil)
        let coordinator = LibraryCoordinator(
            root: fixture.files.root,
            dependencies: LibraryDependencies(activationCheckpoint: { step in
                if step == .beforeFirstOpen, let directory = stagedDirectory.withLock({ $0 }) {
                    try Data("broken database".utf8).write(to: LibraryFiles.database(in: directory))
                }
                if step == .beforeRollback, rollbackFails {
                    throw CocoaError(.fileWriteNoPermission)
                }
            }))
        let seeded = try await fixture.seed(coordinator)
        let staged = try await coordinator.stageRestore(from: fixture.package)
        stagedDirectory.withLock {
            $0 = LibraryFiles.generation(staged.library.generationID, in: fixture.files.root)
        }
        let result = try await coordinator.activateRestore(staged)
        let recovery = try #require(result.recovery)
        if rollbackFails {
            #expect(result.outcome == .recoveryRequired)
            #expect(result.library == nil)
            #expect(result.message.contains("Both generations have been kept"))
            #expect(try fixture.pointer().generationID == staged.library.generationID)
            await #expect(throws: (any Error).self) { _ = try await result.coordinator.open() }
            try LibraryFiles.write(
                ActiveLibrary(formatVersion: 1, generationID: seeded.library.generationID),
                to: fixture.files.root.appending(path: "active-library.json"))
            #expect(try await result.coordinator.open() == seeded.library)
        } else {
            #expect(result.outcome == .keptCurrent)
            #expect(result.library == seeded.library)
        }
        let reader = try RestoreDatabase.open(in: recovery.directory, readonly: true)
        #expect(try await reader.read(WatchQueries.fetchAll).first?.name == "Newer current watch")
        try reader.close()
        try await result.coordinator.close()
    }

    @Test(arguments: [false, true])
    func insufficientSpaceOrSnapshotWriteFailurePreventsSwitch(lowCapacity: Bool) async throws {
        let fixture = ActivationFixture()
        defer { fixture.files.remove() }
        let fail = Mutex(false)
        let coordinator = LibraryCoordinator(
            root: fixture.files.root,
            dependencies: LibraryDependencies(
                backupCheckpoint: { _ in
                    if !lowCapacity && fail.withLock({ $0 }) {
                        throw CocoaError(.fileWriteOutOfSpace)
                    }
                },
                restoreAvailableCapacity: { _ in
                    if lowCapacity && fail.withLock({ $0 }) { return 0 }
                    return Int64.max
                }))
        let seeded = try await fixture.seed(coordinator)
        let staged = try await coordinator.stageRestore(from: fixture.package)
        fail.withLock { $0 = true }
        let result = try await coordinator.activateRestore(staged)
        #expect(result.outcome == .keptCurrent)
        #expect(result.recovery == nil)
        #expect(try fixture.pointer().generationID == seeded.library.generationID)
        #expect(
            try await result.coordinator.read(WatchQueries.fetchAll).first?.name
                == "Newer current watch")
        #expect(result.candidate == staged)
        fail.withLock { $0 = false }
        let retried = try await result.coordinator.activateRestore(staged)
        #expect(retried.outcome == .restored)
        #expect(retried.library == staged.library)
        #expect(retried.candidate == nil)
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.files.root.appending(path: "generations").path
            ).count == 2)
        try await retried.coordinator.close()
    }

    @Test
    func missingCurrentOriginalPreventsAnIncompleteRecoveryAndSwitch() async throws {
        let fixture = ActivationFixture()
        defer { fixture.files.remove() }
        let coordinator = LibraryCoordinator(root: fixture.files.root)
        let seeded = try await fixture.seed(coordinator)
        let staged = try await coordinator.stageRestore(from: fixture.package)
        try FileManager.default.removeItem(at: await coordinator.originalURL(for: seeded.asset.id))
        let result = try await coordinator.activateRestore(staged)
        #expect(result.outcome == .keptCurrent)
        #expect(result.recovery == nil)
        #expect(try fixture.pointer().generationID == seeded.library.generationID)
        try await result.coordinator.close()
    }

    @Test
    func queuedWriteDuringActivationCannotReachEitherGeneration() async throws {
        let fixture = ActivationFixture()
        defer { fixture.files.remove() }
        let reached = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        let coordinator = LibraryCoordinator(
            root: fixture.files.root,
            dependencies: LibraryDependencies(activationCheckpoint: { step in
                if step == .beforeSwitch { reached.signal(); resume.wait() }
            }))
        let seeded = try await fixture.seed(coordinator)
        let staged = try await coordinator.stageRestore(from: fixture.package)
        let activation = Task { try await coordinator.activateRestore(staged) }
        let signalled = await Task.detached { Self.waitForCheckpoint(reached) }.value
        #expect(signalled)
        let queued = Task {
            try await WatchService(coordinator: coordinator).save(
                ActivationFixture.draft("Queued stale watch"), editing: nil)
        }
        resume.signal()
        let result = try await activation.value
        await #expect(throws: LibraryError.notOpen) { _ = try await queued.value }
        #expect(try await result.coordinator.read(WatchQueries.fetchAll).count == 1)
        let reader = try RestoreDatabase.open(
            in: LibraryFiles.generation(seeded.library.generationID, in: fixture.files.root),
            readonly: true)
        #expect(try await reader.read(WatchQueries.fetchAll).count == 1)
        try reader.close()
        try await result.coordinator.close()
    }

    private static func waitForCheckpoint(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 5) == .success
    }
}

nonisolated struct ActivationFixture: Sendable {
    let files = ImportFixture()
    var package: URL { files.directory.appending(path: "activation.watchbackup") }

    func seed(_ coordinator: LibraryCoordinator) async throws -> (
        library: LibraryInfo, asset: FileAsset, bytes: Data
    ) {
        let library = try await coordinator.open()
        var draft = WatchDraft()
        draft.name = "Backup watch"
        let watch = try await WatchService(coordinator: coordinator).save(draft, editing: nil)
        let source = try files.source(type: .png)
        let asset = try await coordinator.importOriginal(from: source, maximumByteCount: 1_000_000)
        _ = try await coordinator.exportBackup(to: package, applicationVersion: "fixture")
        draft.name = "Newer current watch"
        _ = try await WatchService(coordinator: coordinator).save(draft, editing: watch.id)
        return (library, asset, try Data(contentsOf: source))
    }

    static func draft(_ name: String) -> WatchDraft {
        var draft = WatchDraft()
        draft.name = name
        return draft
    }

    func pointer() throws -> ActiveLibrary {
        try LibraryFiles.read(
            ActiveLibrary.self, from: files.root.appending(path: "active-library.json"))
    }
}
