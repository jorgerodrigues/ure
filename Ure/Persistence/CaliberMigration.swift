import Foundation
import GRDB

// A caliber keeps a name, a maker, a winding and four numbers. Before v21 drops the variant,
// the movement type, the specification notes and the source note, this writes their values
// into each caliber's notes, so nothing typed is lost. Manual, Automatic and Quartz become the
// winding. Unknown becomes no winding, and Other goes into the notes.
nonisolated enum CaliberMigration {
    static func preserveRemovedFields(in db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, variant, movementType, specificationNotes, sourceNote, notes
                FROM caliber ORDER BY createdAt, id
                """)
        for row in rows {
            guard
                let text = entry(
                    variant: row["variant"], movementType: row["movementType"],
                    specificationNotes: row["specificationNotes"], sourceNote: row["sourceNote"])
            else { continue }
            let id: String = row["id"]
            let notes: String = row["notes"]
            try db.execute(
                sql: "UPDATE caliber SET notes = ? WHERE id = ?",
                arguments: [OldRecordNotes.appending([text], to: notes), id])
        }
    }

    // One line per removed value, such as "Variant: A/2". Nil when the caliber had none.
    static func entry(
        variant: String?, movementType: String, specificationNotes: String?, sourceNote: String?
    ) -> String? {
        var lines: [String] = []
        if let variant = OldRecordNotes.kept(variant) { lines.append("Variant: \(variant)") }
        if movementType == "Other" { lines.append("Movement type: Other") }
        if let notes = OldRecordNotes.kept(specificationNotes) {
            lines.append("Specification notes: \(notes)")
        }
        if let source = OldRecordNotes.kept(sourceNote) { lines.append("Source note: \(source)") }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }
}
