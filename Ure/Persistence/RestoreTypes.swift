import Foundation

nonisolated struct RestoreSummary: Equatable, Sendable {
    let exportedAt: Date
    let applicationVersion: String
    let counts: [String: Int]
    let originalCount: Int
    let byteCount: Int64
    let appliedMigrations: [String]
}

nonisolated struct StagedRestore: Equatable, Sendable {
    let library: LibraryInfo
    let summary: RestoreSummary
}

nonisolated enum RestoreCheckpoint: Sendable {
    case copiedChunk
    case beforeMigration
    case beforePublish
}

nonisolated enum RestoreError: LocalizedError, Equatable {
    case invalidItem(String, String)
    case unsupportedVersion(Int)
    case unsupportedSchema
    case insufficientSpace(String)
    case migrationFailed

    var errorDescription: String? {
        switch self {
        case .invalidItem(let item, let reason):
            "The backup item \(item) failed validation. \(reason)"
        case .unsupportedVersion(let version):
            "backup.json uses an unsupported backup version (\(version))."
        case .unsupportedSchema:
            "library.sqlite uses database migrations that this version of Ure cannot restore."
        case .insufficientSpace(let item):
            "There is not enough free disk space to stage \(item)."
        case .migrationFailed:
            "library.sqlite could not be upgraded in staging. The current library was kept."
        }
    }
}
