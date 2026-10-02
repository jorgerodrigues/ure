import Foundation

nonisolated struct AppConfiguration: Equatable, Sendable {
    let libraryRoot: URL

    static var current: Self {
        resolve(
            environment: ProcessInfo.processInfo.environment,
            applicationSupportDirectory: .applicationSupportDirectory,
            temporaryDirectory: .temporaryDirectory
        )
    }

    static func resolve(
        environment: [String: String],
        applicationSupportDirectory: URL,
        temporaryDirectory: URL,
        identifier: UUID = UUID()
    ) -> Self {
        if environment["URE_TESTING"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
        {
            let testID =
                environment["URE_TEST_LIBRARY_ID"].flatMap(UUID.init(uuidString:)) ?? identifier
            return Self(
                libraryRoot:
                    temporaryDirectory
                    .appending(path: "UreTests", directoryHint: .isDirectory)
                    .appending(path: testID.uuidString, directoryHint: .isDirectory)
            )
        }

        return Self(
            libraryRoot:
                applicationSupportDirectory
                .appending(path: "Ure/Library", directoryHint: .isDirectory)
        )
    }
}
