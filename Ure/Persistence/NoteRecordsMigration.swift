import Foundation
import GRDB

// Joins the note records of the v6 to v18 schemas into each record's notes text.
nonisolated enum NoteRecordsMigration {
    static func join(in db: Database, locale: Locale, timeZone: TimeZone) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT watchID, jobID, caliberID, title, body, kind, occurredAt FROM note
                ORDER BY occurredAt, createdAt, id
                """)
        var entries: [Owner: [String]] = [:]
        for row in rows {
            entries[try Owner(row), default: []].append(
                entry(
                    title: row["title"], body: row["body"], kind: row["kind"],
                    occurredAt: Date(timeIntervalSince1970: row["occurredAt"]), locale: locale,
                    timeZone: timeZone))
        }
        for (owner, texts) in entries {
            try db.execute(
                sql: "UPDATE \(owner.table) SET notes = ? WHERE id = ?",
                arguments: [texts.joined(separator: "\n\n"), owner.id])
        }
    }

    static func entry(
        title: String, body: String, kind: String, occurredAt: Date, locale: Locale,
        timeZone: TimeZone
    ) -> String {
        var calendar = locale.calendar
        calendar.timeZone = timeZone
        let date = occurredAt.formatted(
            Date.FormatStyle(
                date: .long, time: .omitted, locale: locale, calendar: calendar,
                timeZone: timeZone))
        let heading = "\(date) · \(kind) · \(title)"
        var text = body
        while let last = text.last, last.isWhitespace { text.removeLast() }
        if text.isEmpty { return heading }
        return heading + "\n" + text
    }

    private struct Owner: Hashable {
        let table: String
        let id: String

        init(_ row: Row) throws {
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
                    resultCode: .SQLITE_CONSTRAINT, message: "A note record has no owner.")
            }
        }
    }
}
