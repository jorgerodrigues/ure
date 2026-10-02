import Foundation

extension LibraryCoordinator {
    func documentBytes(for assetID: UUID) throws -> Data {
        let url = try originalURL(for: assetID)
        guard try read({ try FileAssetQueries.fetch(assetID, in: $0)?.detectedType }) == .pdf else {
            throw DocumentError.notPDF
        }
        try Task.checkCancellation()
        return try Data(contentsOf: url)
    }
}
