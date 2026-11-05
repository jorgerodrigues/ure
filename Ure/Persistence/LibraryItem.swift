import Foundation
import GRDB

nonisolated enum LibraryItemKind: String, Codable, Sendable {
    case link = "Link"
    case photo = "Photo"
    case document = "Document"

    var title: String {
        switch self {
        case .link: "Link"
        case .photo: "Photo"
        case .document: "PDF"
        }
    }
}

nonisolated enum LibraryItemOwner: Hashable, Sendable {
    case watch(UUID)
    case job(UUID)
    case caliber(UUID)

    var scope: String {
        switch self {
        case .watch: "Watch"
        case .job: "Job"
        case .caliber: "Caliber"
        }
    }
}

// One piece of material: a photo, a PDF or a link that belongs to one watch, job or caliber.
nonisolated struct LibraryItem: Codable, Equatable, Identifiable, Sendable, FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "libraryItem"

    let id: UUID
    let watchID: UUID?
    let jobID: UUID?
    let caliberID: UUID?
    let kind: LibraryItemKind
    var title: String
    let url: String?
    let fileAssetID: UUID?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID, owner: LibraryItemOwner, kind: LibraryItemKind, title: String, url: String?,
        fileAssetID: UUID?, createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        switch owner {
        case .watch(let ownerID): (watchID, jobID, caliberID) = (ownerID, nil, nil)
        case .job(let ownerID): (watchID, jobID, caliberID) = (nil, ownerID, nil)
        case .caliber(let ownerID): (watchID, jobID, caliberID) = (nil, nil, ownerID)
        }
        self.kind = kind
        self.title = title
        self.url = url
        self.fileAssetID = fileAssetID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var owner: LibraryItemOwner? {
        if let watchID { return .watch(watchID) }
        if let jobID { return .job(jobID) }
        if let caliberID { return .caliber(caliberID) }
        return nil
    }

    func belongs(to owner: LibraryItemOwner) -> Bool {
        switch owner {
        case .watch(let id): watchID == id
        case .job(let id): jobID == id
        case .caliber(let id): caliberID == id
        }
    }

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

nonisolated enum LibraryItemQueries {
    static func fetchAll(_ db: Database) throws -> [LibraryItem] {
        try LibraryItem.fetchAll(db, sql: "SELECT * FROM libraryItem ORDER BY createdAt DESC, id")
    }

    static func fetch(_ id: UUID, in db: Database) throws -> LibraryItem? {
        try LibraryItem.fetchOne(
            db, sql: "SELECT * FROM libraryItem WHERE id = ?", arguments: [id.uuidString])
    }

    static func insert(_ record: LibraryItem, in db: Database) throws {
        try record.insert(db)
        try SearchKey.refresh(record.id, table: .libraryItem, in: db)
    }

    static func update(_ record: LibraryItem, in db: Database) throws {
        try record.update(db)
        try SearchKey.refresh(record.id, table: .libraryItem, in: db)
    }
}
