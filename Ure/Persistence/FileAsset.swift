import Foundation
import GRDB

nonisolated enum FileAssetType: String, Codable, Sendable, CaseIterable {
    case jpeg = "public.jpeg"
    case png = "public.png"
    case heic = "public.heic"
    case pdf = "com.adobe.pdf"
}

nonisolated struct FileAsset: Codable, Equatable, Identifiable, Sendable, FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "fileAsset"

    let id: UUID
    let storageKey: String
    let originalFilename: String
    let detectedType: FileAssetType
    let byteCount: Int64
    let sha256: String
    let importedAt: Date
    let pixelWidth: Int?
    let pixelHeight: Int?
    let orientation: Int?

    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }

    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }

    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
}

nonisolated enum FileAssetQueries {
    static func fetchAll(_ db: Database) throws -> [FileAsset] {
        try FileAsset.fetchAll(db, sql: "SELECT * FROM fileAsset ORDER BY importedAt, id")
    }

    static func fetch(_ id: UUID, in db: Database) throws -> FileAsset? {
        try FileAsset.fetchOne(
            db, sql: "SELECT * FROM fileAsset WHERE id = ?", arguments: [id.uuidString])
    }
}
