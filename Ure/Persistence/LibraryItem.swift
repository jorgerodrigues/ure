import Foundation
import GRDB

nonisolated enum LibraryItemKind: String, Codable, Sendable {
    case link = "Link"
}

nonisolated enum LibraryItemOwner: Equatable, Sendable {
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

nonisolated struct LibraryItem: Codable, Equatable, Identifiable, Sendable, FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "libraryItem"

    let id: UUID
    let watchID: UUID?
    let jobID: UUID?
    let caliberID: UUID?
    let kind: LibraryItemKind
    let title: String
    let sourceURL: String
    let sourceDescription: String
    let notes: String
    let createdAt: Date
    let updatedAt: Date

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

    static func insert(_ record: LibraryItem, in db: Database) throws { try record.insert(db) }
    static func update(_ record: LibraryItem, in db: Database) throws { try record.update(db) }
}
