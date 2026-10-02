import Foundation
import Testing

@testable import Ure

struct AppConfigurationTests {
    private let applicationSupport = URL(filePath: "/isolated-fixture/Application Support")
    private let temporaryDirectory = URL(filePath: "/isolated-fixture/Temporary")

    @Test
    func nativeTestHostUsesAnIsolatedLibrary() {
        #expect(AppConfiguration.current.libraryRoot.pathComponents.contains("UreTests"))
    }

    @Test
    func normalLaunchUsesApplicationSupport() {
        let configuration = AppConfiguration.resolve(
            environment: [:],
            applicationSupportDirectory: applicationSupport,
            temporaryDirectory: temporaryDirectory
        )

        #expect(
            configuration.libraryRoot.path == "/isolated-fixture/Application Support/Ure/Library")
    }

    @Test(arguments: ["URE_TESTING", "XCTestConfigurationFilePath", "XCTestBundlePath"])
    func testLaunchCannotSelectNormalLibrary(marker: String) {
        let configuration = AppConfiguration.resolve(
            environment: [marker: "1"],
            applicationSupportDirectory: applicationSupport,
            temporaryDirectory: temporaryDirectory
        )

        #expect(configuration.libraryRoot.path.hasPrefix("/isolated-fixture/Temporary/UreTests/"))
        #expect(!configuration.libraryRoot.path.hasPrefix(applicationSupport.path))
    }

    @Test
    func independentTestLaunchesHaveDifferentLibraries() {
        let first = AppConfiguration.resolve(
            environment: ["URE_TESTING": "1"],
            applicationSupportDirectory: applicationSupport,
            temporaryDirectory: temporaryDirectory
        )
        let second = AppConfiguration.resolve(
            environment: ["URE_TESTING": "1"],
            applicationSupportDirectory: applicationSupport,
            temporaryDirectory: temporaryDirectory
        )

        #expect(first.libraryRoot != second.libraryRoot)
    }

    @Test
    func restartFixtureStaysIsolatedAndRequiresATestMarker() {
        let id = UUID().uuidString
        let environment = ["URE_TESTING": "1", "URE_TEST_LIBRARY_ID": id]
        let first = AppConfiguration.resolve(
            environment: environment, applicationSupportDirectory: applicationSupport,
            temporaryDirectory: temporaryDirectory)
        let second = AppConfiguration.resolve(
            environment: environment, applicationSupportDirectory: applicationSupport,
            temporaryDirectory: temporaryDirectory)
        #expect(first.libraryRoot == second.libraryRoot)
        #expect(first.libraryRoot.lastPathComponent == id)
        #expect(first.libraryRoot.path.hasPrefix("/isolated-fixture/Temporary/UreTests/"))
        let normal = AppConfiguration.resolve(
            environment: ["URE_TEST_LIBRARY_ID": id],
            applicationSupportDirectory: applicationSupport,
            temporaryDirectory: temporaryDirectory)
        #expect(normal.libraryRoot.path == "/isolated-fixture/Application Support/Ure/Library")
        let invalid = AppConfiguration.resolve(
            environment: ["URE_TESTING": "1", "URE_TEST_LIBRARY_ID": "../../Library"],
            applicationSupportDirectory: applicationSupport, temporaryDirectory: temporaryDirectory)
        #expect(UUID(uuidString: invalid.libraryRoot.lastPathComponent) != nil)
    }
}
