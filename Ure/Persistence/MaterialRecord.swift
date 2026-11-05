import Foundation
import GRDB

// A piece of material with the original file it shows. A link has no file.
nonisolated struct MaterialRecord: Equatable, Identifiable, Sendable {
    let item: LibraryItem
    let asset: FileAsset?
    var id: UUID { item.id }
}

nonisolated enum MaterialQueries {
    static func fetchAll(_ db: Database) throws -> [MaterialRecord] {
        let items = try LibraryItemQueries.fetchAll(db)
        let assets = try FileAsset.fetchAll(
            db,
            sql: """
                SELECT * FROM fileAsset WHERE id IN
                    (SELECT fileAssetID FROM libraryItem WHERE fileAssetID IS NOT NULL)
                """)
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        return items.map { item in
            MaterialRecord(item: item, asset: item.fileAssetID.flatMap { assetsByID[$0] })
        }
    }

    // Removing material keeps its file record and marks it, so that Undo can bring the material
    // back with its original.
    static func markRemoved(_ assetID: UUID, at date: Date, in db: Database) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO removedFileAsset (fileAssetID, removedAt) VALUES (?, ?)",
            arguments: [assetID.uuidString, date.timeIntervalSince1970])
    }

    static func unmarkRemoved(_ assetID: UUID, in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM removedFileAsset WHERE fileAssetID = ?",
            arguments: [assetID.uuidString])
    }

    // When the library opens, no Undo from an earlier session is left. Marked file records that
    // no material uses go, and startup recovery then deletes their originals.
    static func deleteRemovedAssets(in db: Database) throws {
        guard try db.tableExists("removedFileAsset") else { return }
        try db.execute(
            sql: """
                DELETE FROM fileAsset
                WHERE id IN (SELECT fileAssetID FROM removedFileAsset)
                  AND NOT EXISTS
                    (SELECT 1 FROM libraryItem WHERE libraryItem.fileAssetID = fileAsset.id)
                """)
        try db.execute(sql: "DELETE FROM removedFileAsset")
    }
}
