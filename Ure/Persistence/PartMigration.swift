import Foundation
import GRDB

// Before v26, a part was a requirement of one job. It had a description, a quantity, a
// manufacturer reference, a compatibility with a note, one of five statuses with their dates,
// an order reference and a status reason. A part is now a record of its own with a name, a
// description, a quantity, an optional job, one of four states with their dates, and notes.
// The old description becomes the name and the manufacturer reference the description. Arrived
// becomes In hand and Installed becomes Fitted. The compatibility, the order reference and the
// status reason go into the part's notes. A cancelled part goes into its job's notes with its
// links, and is not kept. Saved links stay on their parts. Nothing typed is lost.
nonisolated enum PartMigration {
    static func turnRequirementsIntoParts(
        in db: Database, locale: Locale, timeZone: TimeZone
    ) throws {
        try createPartTable(in: db)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT r.id, r.jobID, r.description, r.quantity, r.manufacturerReference,
                    r.compatibility, r.compatibilityNote, r.status, r.orderedAt, r.arrivedAt,
                    r.installedAt, r.cancelledAt, r.orderReference, r.statusReason, r.createdAt,
                    r.updatedAt
                FROM partRequirement AS r JOIN job ON job.id = r.jobID
                ORDER BY job.createdAt, job.id, r.createdAt, r.id
                """)
        let links = Dictionary(
            grouping: try Row.fetchAll(
                db, sql: "SELECT partID, url FROM partLink ORDER BY position, id"),
            by: { (row: Row) -> String in row["partID"] })
        var jobs: [String] = []
        var cancelled: [String: [String]] = [:]
        var positions: [String: Int] = [:]
        for row in rows {
            let old = OldPart(row: row)
            if old.status == "Cancelled" {
                if cancelled[old.jobID] == nil { jobs.append(old.jobID) }
                let urls = (links[old.id] ?? []).map { (link: Row) -> String in link["url"] }
                cancelled[old.jobID, default: []].append(
                    jobEntry(for: old, links: urls, locale: locale, timeZone: timeZone))
                continue
            }
            let position = positions[old.jobID, default: 0]
            positions[old.jobID] = position + 1
            try insert(old, position: position, locale: locale, timeZone: timeZone, in: db)
        }
        try rebuildLinks(in: db)
        try db.drop(table: "partRequirement")
        for jobID in jobs {
            let notes =
                try String.fetchOne(
                    db, sql: "SELECT notes FROM job WHERE id = ?", arguments: [jobID]) ?? ""
            try db.execute(
                sql: "UPDATE job SET notes = ? WHERE id = ?",
                arguments: [OldRecordNotes.appending(cancelled[jobID] ?? [], to: notes), jobID])
        }
        try SearchKey.backfill("part", fields: ["name", "description", "notes"], in: db)
        try SearchKey.backfill("job", fields: ["title", "notes"], in: db)
    }

    // The new state of a status that is kept. Cancelled parts are not kept.
    static func stage(of status: String) -> PartStage? {
        switch status {
        case "Needed": .needed
        case "Ordered": .ordered
        case "Arrived": .inHand
        case "Installed": .fitted
        default: nil
        }
    }

    // The values a kept part no longer holds, one line each, such as "Compatibility: Confirmed"
    // and "Order reference: PO-1182". Unchecked was the default compatibility, so it is not
    // written. A date its new state does not keep is written too. Nil when there are none.
    static func partEntry(
        for old: OldPart, stage: PartStage, locale: Locale, timeZone: TimeZone
    ) -> String? {
        var lines = removedValues(of: old)
        lines += dates(of: old, keptBy: stage).map { $0.line(locale, timeZone) }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    // A cancelled part in its job's notes, after a line with its name, such as "Part ·
    // Mainspring", followed by every value it held and its links.
    static func jobEntry(
        for old: OldPart, links: [String], locale: Locale, timeZone: TimeZone
    ) -> String {
        var lines = ["Part · \(old.description)"]
        if old.quantity != 1 { lines.append("Quantity: \(old.quantity)") }
        if let reference = OldRecordNotes.kept(old.manufacturerReference) {
            lines.append("Manufacturer reference: \(reference)")
        }
        lines += removedValues(of: old, cancelled: true)
        lines.append(
            OldRecordNotes.kept(old.statusReason).map { "Cancelled: \($0)" } ?? "Cancelled")
        lines += dates(of: old, keptBy: nil).map { $0.line(locale, timeZone) }
        lines += links.map { "Link: \($0)" }
        return lines.joined(separator: "\n")
    }

    private static func removedValues(of old: OldPart, cancelled: Bool = false) -> [String] {
        var lines: [String] = []
        func add(_ label: String, _ value: String?) {
            if let value = OldRecordNotes.kept(value) { lines.append("\(label): \(value)") }
        }
        if old.compatibility != "Unchecked" { lines.append("Compatibility: \(old.compatibility)") }
        add("Compatibility note", old.compatibilityNote)
        add("Order reference", old.orderReference)
        // A cancelled part's reason says why it was cancelled, on its own line.
        if !cancelled { add("Status reason", old.statusReason) }
        return lines
    }

    // The old dates that the new state does not keep, oldest milestone first. A cancelled part
    // keeps none of them.
    private static func dates(of old: OldPart, keptBy stage: PartStage?) -> [OldDate] {
        let milestones: [(label: String, date: Date?, keptFrom: PartStage?)] = [
            ("Ordered", old.orderedAt, .ordered), ("Arrived", old.arrivedAt, .inHand),
            ("Installed", old.installedAt, .fitted), ("Cancelled", old.cancelledAt, nil),
        ]
        return milestones.compactMap { milestone in
            guard let date = milestone.date else { return nil }
            if let stage, let keptFrom = milestone.keptFrom, stage.hasReached(keptFrom) {
                return nil
            }
            return OldDate(label: milestone.label, date: date)
        }
    }

    struct OldDate {
        let label: String
        let date: Date

        func line(_ locale: Locale, _ timeZone: TimeZone) -> String {
            "\(label) on \(PartMigration.day(date, locale, timeZone))"
        }
    }

    private static func insert(
        _ old: OldPart, position: Int, locale: Locale, timeZone: TimeZone, in db: Database
    ) throws {
        guard let stage = stage(of: old.status) else { return }
        let entry = partEntry(for: old, stage: stage, locale: locale, timeZone: timeZone)
        let notes = entry.map { OldRecordNotes.appending([$0], to: "") } ?? ""
        try db.execute(
            sql: """
                INSERT INTO part (id, jobID, position, name, description, quantity, stage,
                    orderedAt, inHandAt, fittedAt, notes, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                old.id, old.jobID, position, old.description,
                OldRecordNotes.kept(old.manufacturerReference), old.quantity, stage.rawValue,
                stage.hasReached(.ordered) ? old.orderedAt?.timeIntervalSince1970 : nil,
                stage.hasReached(.inHand) ? old.arrivedAt?.timeIntervalSince1970 : nil,
                stage.hasReached(.fitted) ? old.installedAt?.timeIntervalSince1970 : nil,
                notes, old.createdAt, old.updatedAt,
            ])
    }

    static func createPartTable(in db: Database) throws {
        try db.create(table: "part") { table in
            table.column("id", .text).primaryKey()
            table.column("jobID", .text).references("job", onDelete: .restrict)
            table.column("position", .integer).notNull().defaults(to: 0).check { $0 >= 0 }
            table.column("name", .text).notNull().check(sql: "length(trim(name)) > 0")
            table.column("description", .text)
            table.column("quantity", .integer).notNull().defaults(to: 1)
                .check(sql: "typeof(quantity) = 'integer' AND quantity > 0")
            table.column("stage", .text).notNull()
                .check(sql: "stage IN ('Needed', 'Ordered', 'In hand', 'Fitted')")
            for column in ["orderedAt", "inHandAt", "fittedAt"] {
                table.column(column, .double)
            }
            table.column("notes", .text).notNull().defaults(to: "")
            table.column("searchKey", .text).notNull().defaults(to: "")
            table.column("createdAt", .double).notNull()
            table.column("updatedAt", .double).notNull()
            // A part keeps only the dates of the states it has reached.
            table.check(sql: "stage != 'Needed' OR orderedAt IS NULL")
            table.check(sql: "stage IN ('In hand', 'Fitted') OR inHandAt IS NULL")
            table.check(sql: "stage = 'Fitted' OR fittedAt IS NULL")
        }
        try db.create(index: "part_jobID_position", on: "part", columns: ["jobID", "position"])
        try db.create(index: "part_stage", on: "part", columns: ["stage"])
        try db.create(index: "part_searchKey", on: "part", columns: ["searchKey"])
    }

    // The links of the kept parts move to a table that refers to the part table. The links of
    // cancelled parts are in their job's notes.
    private static func rebuildLinks(in db: Database) throws {
        try db.create(table: "partLink_new") { table in
            table.column("id", .text).primaryKey()
            table.column("partID", .text).notNull().references("part", onDelete: .restrict)
            table.column("position", .integer).notNull().check { $0 >= 0 }
            table.column("url", .text).notNull().check(sql: "length(trim(url)) > 0")
            table.column("createdAt", .double).notNull()
            table.column("updatedAt", .double).notNull()
        }
        try db.execute(
            sql: """
                INSERT INTO partLink_new (id, partID, position, url, createdAt, updatedAt)
                SELECT id, partID, position, url, createdAt, updatedAt FROM partLink
                WHERE partID IN (SELECT id FROM part)
                """)
        try db.drop(table: "partLink")
        try db.rename(table: "partLink_new", to: "partLink")
        try db.create(
            index: "partLink_partID_position", on: "partLink", columns: ["partID", "position"])
    }

    private static func day(_ date: Date, _ locale: Locale, _ timeZone: TimeZone) -> String {
        var calendar = locale.calendar
        calendar.timeZone = timeZone
        return date.formatted(
            Date.FormatStyle(
                date: .long, time: .omitted, locale: locale, calendar: calendar,
                timeZone: timeZone))
    }

    // A part requirement as the schema before v26 held it.
    struct OldPart {
        let id: String
        let jobID: String
        let description: String
        let quantity: Int
        let manufacturerReference: String?
        let compatibility: String
        let compatibilityNote: String?
        let status: String
        let orderedAt: Date?
        let arrivedAt: Date?
        let installedAt: Date?
        let cancelledAt: Date?
        let orderReference: String?
        let statusReason: String?
        let createdAt: Double
        let updatedAt: Double

        init(row: Row) {
            id = row["id"]
            jobID = row["jobID"]
            description = row["description"]
            quantity = row["quantity"]
            manufacturerReference = row["manufacturerReference"]
            compatibility = row["compatibility"]
            compatibilityNote = row["compatibilityNote"]
            status = row["status"]
            orderedAt = Self.date(row["orderedAt"])
            arrivedAt = Self.date(row["arrivedAt"])
            installedAt = Self.date(row["installedAt"])
            cancelledAt = Self.date(row["cancelledAt"])
            orderReference = row["orderReference"]
            statusReason = row["statusReason"]
            createdAt = row["createdAt"]
            updatedAt = row["updatedAt"]
        }

        private static func date(_ value: Double?) -> Date? {
            value.map { Date(timeIntervalSince1970: $0) }
        }
    }
}
