import Foundation
import GRDB

// Material keeps only its kind, title, file or link, and date. Before v20 drops the other item
// fields, this writes their values into the owning record's notes, so nothing typed is lost.
nonisolated enum MaterialMigration {
    static let heading = "From the old record"

    static func preserveRemovedFields(in db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT watchID, jobID, caliberID, kind, title, sourceURL, sourceDescription, notes,
                    photoStage, caption
                FROM libraryItem ORDER BY createdAt, id
                """)
        var owners: [MigratedOwner] = []
        var entries: [MigratedOwner: [String]] = [:]
        for row in rows {
            guard
                let text = entry(
                    kind: row["kind"], title: row["title"], sourceURL: row["sourceURL"],
                    sourceDescription: row["sourceDescription"], notes: row["notes"],
                    photoStage: row["photoStage"], caption: row["caption"])
            else { continue }
            let owner = try MigratedOwner(row, record: "library item")
            if entries[owner] == nil { owners.append(owner) }
            entries[owner, default: []].append(text)
        }
        for owner in owners {
            let notes =
                try String.fetchOne(
                    db, sql: "SELECT notes FROM \(owner.table) WHERE id = ?", arguments: [owner.id])
                ?? ""
            try db.execute(
                sql: "UPDATE \(owner.table) SET notes = ? WHERE id = ?",
                arguments: [appending(entries[owner] ?? [], to: notes), owner.id])
        }
    }

    // One item's removed values, after a line with its kind and title. Nil when it had none.
    static func entry(
        kind: String, title: String, sourceURL: String, sourceDescription: String, notes: String,
        photoStage: String?, caption: String?
    ) -> String? {
        var lines: [String] = []
        if let photoStage, photoStage != "Unclassified" { lines.append("Stage: \(photoStage)") }
        if let caption = kept(caption) { lines.append("Caption: \(caption)") }
        if kind != "Link", let sourceURL = kept(sourceURL) {
            lines.append("Source URL: \(sourceURL)")
        }
        if let sourceDescription = kept(sourceDescription) {
            lines.append("Source description: \(sourceDescription)")
        }
        if let notes = kept(notes) { lines.append("Notes: \(notes)") }
        guard !lines.isEmpty else { return nil }
        let label = LibraryItemKind(rawValue: kind)?.title ?? kind
        return (["\(label) · \(title)"] + lines).joined(separator: "\n")
    }

    // Adds the heading and entries after the existing notes, with one blank line between them.
    // The existing text keeps every character.
    static func appending(_ entries: [String], to notes: String) -> String {
        guard !entries.isEmpty else { return notes }
        let block = ([heading] + entries).joined(separator: "\n\n")
        if notes.isEmpty || notes.hasSuffix("\n\n") { return notes + block }
        if notes.hasSuffix("\n") { return notes + "\n" + block }
        return notes + "\n\n" + block
    }

    private static func kept(_ value: String?) -> String? {
        guard var value else { return nil }
        while let last = value.last, last.isWhitespace { value.removeLast() }
        guard value.contains(where: { !$0.isWhitespace }) else { return nil }
        return value
    }
}

// The watch, job or caliber that a row from an old child table belongs to.
nonisolated struct MigratedOwner: Hashable {
    let table: String
    let id: String

    init(_ row: Row, record: String) throws {
        if let id: String = row["watchID"] {
            table = "watch"
            self.id = id
        } else if let id: String = row["jobID"] {
            table = "job"
            self.id = id
        } else if let id: String = row["caliberID"] {
            table = "caliber"
            self.id = id
        } else {
            throw DatabaseError(
                resultCode: .SQLITE_CONSTRAINT, message: "A \(record) record has no owner.")
        }
    }
}
