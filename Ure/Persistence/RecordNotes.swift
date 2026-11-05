import Foundation
import GRDB

nonisolated enum RecordNotesQueries {
    static func fetch(_ owner: LibraryItemOwner, in db: Database) throws -> String? {
        try String.fetchOne(
            db, sql: "SELECT notes FROM \(owner.table.rawValue) WHERE id = ?",
            arguments: [owner.recordID.uuidString])
    }

    static func update(
        _ text: String, for owner: LibraryItemOwner, at date: Date, in db: Database
    ) throws {
        try db.execute(
            sql: "UPDATE \(owner.table.rawValue) SET notes = ?, updatedAt = ? WHERE id = ?",
            arguments: [text, date.timeIntervalSince1970, owner.recordID.uuidString])
        try SearchKey.refresh(owner.recordID, table: owner.table, in: db)
    }
}

extension LibraryItemOwner {
    nonisolated fileprivate var recordID: UUID {
        switch self {
        case .watch(let id), .job(let id), .caliber(let id): id
        }
    }

    nonisolated fileprivate var table: SearchKey.Table {
        switch self {
        case .watch: .watch
        case .job: .job
        case .caliber: .caliber
        }
    }
}
