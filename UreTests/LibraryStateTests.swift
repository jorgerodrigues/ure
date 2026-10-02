import Foundation
import GRDB
import Testing

@testable import Ure

struct LibraryStateTests {
    @Test
    func nativeFixtureRequiresAnExplicitTestMarker() async throws {
        let root = URL.temporaryDirectory.appending(path: "UreTests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = LibraryTestSeed.dependencies(
            environment: ["URE_TEST_CORRUPT_POINTER": "1"])
        let coordinator = LibraryCoordinator(root: root, dependencies: dependencies)
        _ = try await coordinator.open()
        #expect(
            try await coordinator.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM libraryMetadata")
            } == 1)
        try await coordinator.close()
    }

    @Test
    func failedStartupShowsRecoveryAndRetryCanOpenTheRepairedLibrary() async throws {
        let root = URL.temporaryDirectory.appending(path: "UreTests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appending(path: "existing-library")
        try Data("preserve this file".utf8).write(to: blocker)
        let state = LibraryState(coordinator: LibraryCoordinator(root: root))
        await state.open()
        guard case .recovery(let reason) = state.phase else {
            Issue.record("Failed startup must show recovery")
            return
        }
        #expect(reason.contains("pointer is missing"))
        await state.open()
        #expect(state.phase == .recovery(reason))
        #expect(try Data(contentsOf: blocker) == Data("preserve this file".utf8))
        try FileManager.default.removeItem(at: blocker)
        await state.open()
        guard case .ready(let info) = state.phase else {
            Issue.record("Retry must open a valid library")
            return
        }
        await state.open()
        #expect(state.phase == .ready(info))
        try await state.coordinator.close()
    }
}
