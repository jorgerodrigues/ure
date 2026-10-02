import Foundation

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

nonisolated struct FileImportResult: Sendable {
    let source: URL
    let outcome: Result<FileAsset, FileImportError>
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
    let coordinator: LibraryCoordinator
    var maximumByteCount: Int64 = 100_000_000
    var maximumFileCount: Int = 200

    func importFiles(_ sources: [URL]) async -> [FileImportResult] {
        guard sources.count <= maximumFileCount else {
            return sources.map {
                FileImportResult(source: $0, outcome: .failure(.tooManyFiles(maximumFileCount)))
            }
        }
        var results: [FileImportResult] = []
        for source in sources {
            let outcome: Result<FileAsset, FileImportError>
            do {
                let asset = try await coordinator.importOriginal(
                    from: source, maximumByteCount: maximumByteCount)
                outcome = .success(asset)
            } catch is CancellationError {
                outcome = .failure(.cancelled)
            } catch let error as FileImportError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.storageFailure(error.localizedDescription))
            }
            results.append(FileImportResult(source: source, outcome: outcome))
        }
        return results
    }
}
