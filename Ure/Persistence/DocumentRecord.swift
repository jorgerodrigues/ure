import Foundation
import GRDB

nonisolated struct DocumentRecord: Equatable, Identifiable, Sendable {
    let item: LibraryItem
    let asset: FileAsset
    var id: UUID { item.id }
}

nonisolated enum DocumentQueries {
    static func fetchAll(_ db: Database) throws -> [DocumentRecord] {
        let items = try LibraryItem.fetchAll(
            db, sql: "SELECT * FROM libraryItem WHERE kind = 'Document' ORDER BY createdAt DESC, id"
        )
        let assets = try FileAsset.fetchAll(
            db,
            sql:
                "SELECT * FROM fileAsset WHERE id IN (SELECT fileAssetID FROM libraryItem WHERE kind = 'Document')"
        )
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        return try items.map { item in
            guard let id = item.fileAssetID, let asset = assetsByID[id], asset.detectedType == .pdf
            else {
                throw DocumentError.missingRecord
            }
            return DocumentRecord(item: item, asset: asset)
        }
    }
}
