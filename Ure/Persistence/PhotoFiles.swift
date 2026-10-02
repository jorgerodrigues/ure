import Foundation

extension LibraryCoordinator {
    func photoOriginal(for assetID: UUID) throws -> (url: URL, maximumPixelSize: Int) {
        let url = try originalURL(for: assetID)
        let asset = try read { try FileAssetQueries.fetch(assetID, in: $0) }
        guard let asset, asset.detectedType != .pdf,
            let width = asset.pixelWidth, let height = asset.pixelHeight
        else { throw PhotoError.notPhoto }
        return (url, max(width, height))
    }

    func exportOriginal(_ assetID: UUID, to destination: URL) throws {
        let original = try originalURL(for: assetID)
        let resolved = destination.resolvingSymlinksInPath().path
        let libraryPath = root.resolvingSymlinksInPath().path
        guard destination.isFileURL,
            resolved != libraryPath, !resolved.hasPrefix(libraryPath + "/")
        else { throw LibraryError.invalidLibrary("Choose an export location outside the library.") }
        let access = destination.startAccessingSecurityScopedResource()
        defer { if access { destination.stopAccessingSecurityScopedResource() } }
        let replacement = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination,
            create: true)
        defer { try? FileManager.default.removeItem(at: replacement) }
        let staged = replacement.appending(path: "original")
        try Task.checkCancellation()
        try FileManager.default.copyItem(at: original, to: staged)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
    }
}
