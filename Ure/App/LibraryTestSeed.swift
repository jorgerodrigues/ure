#if DEBUG
    import Foundation

    nonisolated enum LibraryTestSeed {
        static func dependencies(environment: [String: String]) -> LibraryDependencies {
            var dependencies = LibraryDependencies()
            if environment["URE_TESTING"] == "1", environment["URE_TEST_CORRUPT_POINTER"] == "1" {
                dependencies.prepareLibrary = { root in
                    try FileManager.default.createDirectory(
                        at: root, withIntermediateDirectories: true)
                    try Data("damaged pointer fixture".utf8)
                        .write(to: root.appending(path: "active-library.json"))
                }
            }
            return dependencies
        }
    }
#endif
