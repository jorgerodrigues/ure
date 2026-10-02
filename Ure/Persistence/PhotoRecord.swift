import Foundation
import GRDB

nonisolated struct PhotoRecord: Equatable, Identifiable, Sendable {
    let item: LibraryItem
    let asset: FileAsset
    var id: UUID { item.id }
}

nonisolated enum PhotoQueries {
    static func fetchAll(_ db: Database) throws -> [PhotoRecord] {
        let items = try LibraryItem.fetchAll(
            db,
            sql: """
                SELECT * FROM libraryItem WHERE kind = 'Photo' ORDER BY createdAt DESC, id
                """)
        let assets = try FileAsset.fetchAll(
            db,
            sql: """
                SELECT * FROM fileAsset WHERE id IN
                    (SELECT fileAssetID FROM libraryItem WHERE kind = 'Photo')
                """)
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        return try items.map { item in
            guard let id = item.fileAssetID, let asset = assetsByID[id] else {
                throw PhotoError.missingRecord
            }
            return PhotoRecord(item: item, asset: asset)
        }
    }
}
