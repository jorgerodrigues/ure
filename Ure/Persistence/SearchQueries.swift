import Foundation
import GRDB

nonisolated enum SearchKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case watch = "Watch"
    case caliber = "Caliber"
    case job = "Job"
    case part = "Part"
    case link = "Link"
    case photo = "Photo"
    case document = "Document"

    var id: Self { self }

    var title: String {
        switch self {
        case .document: "PDF"
        default: rawValue
        }
    }
}

nonisolated struct SearchResult: Decodable, Equatable, Identifiable, Sendable, FetchableRecord {
    let recordID: UUID
    let kind: SearchKind
    let title: String
    let watchID: UUID?
    let jobID: UUID?
    let caliberID: UUID?
    let watchName: String?
    let jobTitle: String?
    let caliberLabel: String?
    let isArchived: Bool

    var id: String { "\(kind.rawValue)-\(recordID.uuidString)" }
    var context: String {
        if let jobTitle, let watchName { return "\(watchName) · \(jobTitle)" }
        if let watchName { return "Watch · \(watchName)" }
        if let caliberLabel { return "Caliber · \(caliberLabel)" }
        return kind.rawValue
    }

    var itemOwner: LibraryItemOwner? {
        if let jobID { return .job(jobID) }
        if let caliberID { return .caliber(caliberID) }
        if let watchID { return .watch(watchID) }
        return nil
    }
}

nonisolated enum SearchQueries {
    // Archived records are found too, and say that they are archived.
    static func fetch(_ text: String, in db: Database) throws -> [SearchResult] {
        let key = SearchKey.normalize(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !key.isEmpty else { return [] }
        return try SearchResult.fetchAll(
            db,
            sql: """
                WITH results AS (
                    SELECT r.id AS recordID, 'Watch' AS kind, r.name AS title,
                        r.id AS watchID, NULL AS jobID, NULL AS caliberID,
                        r.name AS watchName, NULL AS jobTitle, NULL AS caliberLabel,
                        r.archivedAt IS NOT NULL AS isArchived, r.searchKey
                    FROM watch r
                    UNION ALL
                    SELECT r.id, 'Caliber', \(caliberTitle("r")),
                        NULL, NULL, r.id, NULL, NULL,
                        \(caliberTitle("r")), r.archivedAt IS NOT NULL, r.searchKey
                    FROM caliber r
                    UNION ALL
                    SELECT r.id, 'Job', r.title, w.id, r.id, NULL,
                        w.name, r.title, NULL,
                        r.archivedAt IS NOT NULL OR w.archivedAt IS NOT NULL, r.searchKey
                    FROM job r JOIN watch w ON w.id = r.watchID
                    UNION ALL
                    SELECT r.id, 'Part', r.description, w.id, j.id, NULL,
                        w.name, j.title, NULL,
                        w.archivedAt IS NOT NULL OR j.archivedAt IS NOT NULL, r.searchKey
                    FROM partRequirement r
                    JOIN job j ON j.id = r.jobID JOIN watch w ON w.id = j.watchID
                    UNION ALL
                    SELECT r.id, r.kind, r.title, w.id, j.id, c.id,
                        w.name, j.title, \(caliberTitle("c")),
                        w.archivedAt IS NOT NULL OR j.archivedAt IS NOT NULL
                            OR c.archivedAt IS NOT NULL, r.searchKey
                    FROM libraryItem r
                    LEFT JOIN job j ON j.id = r.jobID
                    LEFT JOIN watch w ON w.id = coalesce(r.watchID, j.watchID)
                    LEFT JOIN caliber c ON c.id = r.caliberID
                )
                SELECT * FROM results WHERE instr(searchKey, ?) > 0
                ORDER BY kind, title, recordID
                """, arguments: [key])
    }

    // A caliber's maker and name in SQL, such as "Omega 552", as CaliberRecord.title gives it.
    private static func caliberTitle(_ table: String) -> String {
        "coalesce(nullif(\(table).manufacturer, '') || ' ', '') || \(table).designation"
    }
}
