import Foundation

nonisolated struct LibraryDependencies: Sendable {
    var makeID: @Sendable () -> UUID = { UUID() }
    var now: @Sendable () -> Date = { Date() }
    var prepareLibrary: @Sendable (URL) throws -> Void = { _ in }
}

nonisolated struct LibraryManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let formatVersion: Int
    let libraryID: UUID
    let createdAt: Date
}

nonisolated struct ActiveLibrary: Codable, Sendable {
    let formatVersion: Int
    let generationID: UUID
}

nonisolated struct LibraryInfo: Equatable, Sendable {
    let generationID: UUID
    let manifest: LibraryManifest
}

nonisolated struct LibrarySnapshot: Sendable {
    let directory: URL
    let createdAt: Date
    let files: [SnapshotFile]
}

nonisolated struct SnapshotFile: Codable, Equatable, Sendable {
    let path: String
    let byteCount: Int64
    let sha256: String
}

nonisolated struct SnapshotManifest: Codable, Sendable {
    let formatVersion: Int
    let createdAt: Date
    let files: [SnapshotFile]
}

nonisolated enum LibraryError: LocalizedError, Equatable {
    case invalidLibrary(String)
    case unsupportedFormat(Int)
    case unsupportedSchema
    case notOpen

    var errorDescription: String? {
        switch self {
        case .invalidLibrary(let reason):
            reason
        case .unsupportedFormat(let version):
            "This library uses an unsupported storage format (\(version))."
        case .unsupportedSchema:
            "This library uses database migrations that this version of Ure cannot open."
        case .notOpen:
            "The library is not open."
        }
    }
}
