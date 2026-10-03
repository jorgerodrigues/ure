import Foundation

nonisolated enum LibraryFiles {
    static func generation(_ id: UUID, in root: URL) -> URL {
        root.appending(path: "generations", directoryHint: .isDirectory)
            .appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    static func database(in directory: URL) -> URL {
        directory.appending(path: "library.sqlite")
    }

    static func originals(in directory: URL) -> URL {
        directory.appending(path: "originals", directoryHint: .isDirectory)
    }

    static func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        try requireRegularFile(url)
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    static func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw LibraryError.invalidLibrary("A required library folder is missing or invalid.")
        }
    }

    static func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LibraryError.invalidLibrary("A required library file is missing or invalid.")
        }
    }

    static func validateVersion(_ version: Int) throws {
        guard version == LibraryManifest.currentVersion else {
            throw LibraryError.unsupportedFormat(version)
        }
    }

    static func relativePath(_ url: URL, in directory: URL) throws -> String {
        let prefix = directory.resolvingSymlinksInPath().path + "/"
        let path = url.resolvingSymlinksInPath().path
        guard path.hasPrefix(prefix) else {
            throw LibraryError.invalidLibrary("A snapshot file is outside its library folder.")
        }
        return String(path.dropFirst(prefix.count))
    }

    static func originalFiles(in directory: URL) throws -> [URL] {
        try requireDirectory(directory)
        var files: [URL] = []
        for child in try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw LibraryError.invalidLibrary(
                    "The original file store contains a symbolic link.")
            }
            if values.isDirectory == true {
                files += try originalFiles(in: child)
            } else {
                try requireRegularFile(child)
                files.append(child)
            }
        }
        return files.sorted { $0.path < $1.path }
    }
}
