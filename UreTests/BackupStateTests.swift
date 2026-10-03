import Foundation
import Testing

@testable import Ure

struct BackupStateTests {
    @Test
    func successPersistsExportTimeAndFailedExportKeepsIt() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let suite = "UreBackupTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let date = Date(timeIntervalSince1970: 1_700_000_000.5)
        let coordinator = LibraryCoordinator(
            root: fixture.root, dependencies: LibraryDependencies(now: { date }))
        _ = try await coordinator.open()
        let state = BackupState(coordinator: coordinator, defaults: defaults)
        #expect(state.lastExport == nil)
        await state.refresh()
        #expect(state.summary?.date == date)
        let destination = fixture.directory.appending(path: "success.watchbackup")
        state.export(to: destination)
        state.export(to: fixture.directory.appending(path: "duplicate.watchbackup"))
        await state.waitForCompletion()
        #expect(state.lastExport == date)
        #expect(state.message == "Backup exported to success.watchbackup.")
        #expect(state.errorMessage == nil)
        #expect(!state.isExporting)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.directory.appending(path: "duplicate.watchbackup").path))
        let reopened = BackupState(coordinator: coordinator, defaults: defaults)
        #expect(reopened.lastExport == date)
        state.export(to: fixture.root.appending(path: "forbidden.watchbackup"))
        await state.waitForCompletion()
        #expect(state.lastExport == date)
        #expect(state.message == nil)
        #expect(state.errorMessage?.contains("Export failed") == true)
        #expect(BackupState(coordinator: coordinator, defaults: defaults).lastExport == date)
        try await coordinator.close()
    }

    @Test
    func cancellationDoesNotClaimSuccessOrUpdateExportTime() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let suite = "UreBackupTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let state = BackupState(coordinator: coordinator, defaults: defaults)
        let destination = fixture.directory.appending(path: "cancelled.watchbackup")
        state.export(to: destination)
        state.cancel()
        await state.waitForCompletion()
        #expect(state.lastExport == nil)
        #expect(state.message?.contains("cancelled") == true)
        #expect(state.errorMessage == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!state.isExporting)
        try await coordinator.close()
    }

    @Test
    func unavailableLibraryHasNoExportSummary() async {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let state = BackupState(coordinator: LibraryCoordinator(root: fixture.root))
        await state.refresh()
        #expect(state.summary == nil)
        #expect(state.errorMessage != nil)
        #expect(!state.isLoading)
    }
}
