import Foundation
import GRDB

nonisolated enum FileImportError: LocalizedError, Equatable {
    case unsupportedType
    case corruptContent
    case encryptedPDF
    case oversized(Int64)
    case tooManyFiles(Int)
    case invalidSource
    case cancelled
    case storageFailure(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedType: "Choose a JPEG, PNG, HEIC, or PDF file."
        case .corruptContent: "This file is incomplete or cannot be decoded."
        case .encryptedPDF: "Password-protected PDF files are not supported."
        case .oversized(let limit): "This original exceeds the \(limit) byte import limit."
        case .tooManyFiles(let limit): "Choose at most \(limit) files per import."
        case .invalidSource: "Choose a regular local file. Symbolic links are not supported."
        case .cancelled: "Import was cancelled. Files already imported have been kept."
        case .storageFailure(let reason): "The original could not be saved. \(reason)"
        }
    }
}

nonisolated struct FileImportResult<Value: Sendable>: Identifiable, Sendable {
    let id = UUID()
    let source: URL
    let outcome: Result<Value, any Error>
}

nonisolated enum FileImportCheckpoint: Sendable {
    case copiedChunk
    case beforeRename
    case afterRename
    case beforeCommit
    case afterCommit
    case beforeCleanup
}

nonisolated struct FileImportService: Sendable {
    static let defaultMaximumByteCount: Int64 = 100_000_000
    static let defaultMaximumFileCount = 200
    let coordinator: LibraryCoordinator
    var maximumByteCount: Int64 = Self.defaultMaximumByteCount
    var maximumFileCount: Int = Self.defaultMaximumFileCount

    func importFiles(_ sources: [URL]) async -> [FileImportResult<FileAsset>] {
        let results = await importFiles(sources) { _, asset, _ in asset }
        return results.map { result in
            FileImportResult(
                source: result.source, outcome: result.outcome.mapError(Self.importError))
        }
    }

    static func importError(_ error: any Error) -> any Error {
        if let error = error as? FileImportError { return error }
        return FileImportError.storageFailure(error.localizedDescription)
    }

    func importFiles<Value: Sendable>(
        _ sources: [URL],
        validate: @Sendable (URL, FileAsset) throws -> Void = { _, _ in },
        commit: @Sendable (Database, FileAsset, LibraryDependencies) throws -> Value
    ) async -> [FileImportResult<Value>] {
        guard sources.count <= maximumFileCount else {
            return sources.map {
                FileImportResult(
                    source: $0, outcome: .failure(FileImportError.tooManyFiles(maximumFileCount)))
            }
        }
        var results: [FileImportResult<Value>] = []
        for source in sources {
            let outcome: Result<Value, any Error>
            do {
                let asset = try await coordinator.importOriginal(
                    from: source, maximumByteCount: maximumByteCount, validate: validate,
                    commit: commit)
                outcome = .success(asset)
            } catch is CancellationError {
                outcome = .failure(FileImportError.cancelled)
            } catch {
                outcome = .failure(error)
            }
            results.append(FileImportResult(source: source, outcome: outcome))
        }
        return results
    }
}
