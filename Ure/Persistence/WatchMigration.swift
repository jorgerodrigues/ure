import Foundation
import GRDB

// Before v22, each job kept its owner's name, email and phone, and each watch kept a condition,
// a condition note, a stated water resistance and specification notes. The owner moves to the
// watch, from its most recent job that names one, with the email and phone joined into one
// contact. Owners that other jobs name differently, and the watch fields that go, are written
// into the watch's notes, so nothing typed is lost.
nonisolated enum WatchMigration {
    // An owner as a job recorded it. Blank values are no value.
    struct Owner: Equatable {
        let name: String?
        let email: String?
        let phone: String?

        init(name: String?, email: String?, phone: String?) {
            self.name = OldRecordNotes.kept(name)
            self.email = OldRecordNotes.kept(email)
            self.phone = OldRecordNotes.kept(phone)
        }

        var isEmpty: Bool { name == nil && email == nil && phone == nil }

        // The email and the phone as one contact, such as "ana@example.pt · +351 912 480 117".
        var contact: String? {
            let parts = [email, phone].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    struct Job {
        let title: String
        let owner: Owner
    }

    static func moveRemovedFields(in db: Database) throws {
        let jobs = try Row.fetchAll(
            db,
            sql: """
                SELECT watchID, title, ownerName, ownerEmail, ownerPhone FROM job
                ORDER BY createdAt DESC, id
                """)
        var newestFirst: [String: [Job]] = [:]
        for row in jobs {
            let watchID: String = row["watchID"]
            let owner = Owner(
                name: row["ownerName"], email: row["ownerEmail"], phone: row["ownerPhone"])
            newestFirst[watchID, default: []].append(Job(title: row["title"], owner: owner))
        }
        let watches = try Row.fetchAll(
            db,
            sql: """
                SELECT id, condition, conditionNote, waterResistance, specificationNotes, notes
                FROM watch ORDER BY createdAt, id
                """)
        for row in watches {
            let id: String = row["id"]
            let jobs = newestFirst[id] ?? []
            let owner = currentOwner(of: jobs)
            var entries: [String] = []
            if let fields = entry(
                condition: row["condition"], conditionNote: row["conditionNote"],
                waterResistance: row["waterResistance"],
                specificationNotes: row["specificationNotes"])
            {
                entries.append(fields)
            }
            entries += otherOwners(in: jobs, keeping: owner)
            let notes: String = row["notes"]
            try db.execute(
                sql: "UPDATE watch SET owner = ?, contact = ?, notes = ? WHERE id = ?",
                arguments: [
                    owner?.name.map(trimmed), owner?.contact.map(trimmed),
                    OldRecordNotes.appending(entries, to: notes), id,
                ])
        }
    }

    // The owner of the most recent job that names one, given the jobs newest first.
    static func currentOwner(of jobs: [Job]) -> Owner? {
        jobs.first { !$0.owner.isEmpty }?.owner
    }

    // One entry for each job, oldest first, whose owner differs from the one the watch keeps,
    // such as "Job · Full service" followed by "Owner: Ana Ribeiro".
    static func otherOwners(in jobs: [Job], keeping owner: Owner?) -> [String] {
        jobs.reversed().compactMap { job in
            guard !job.owner.isEmpty, job.owner != owner else { return nil }
            var lines = ["Job · \(job.title)"]
            if let name = job.owner.name { lines.append("Owner: \(name)") }
            if let email = job.owner.email { lines.append("Email: \(email)") }
            if let phone = job.owner.phone { lines.append("Phone: \(phone)") }
            return lines.joined(separator: "\n")
        }
    }

    // One line per watch value that goes, such as "Condition: Stopped". Unknown was the default
    // condition, so it is not written. Nil when the watch had none.
    static func entry(
        condition: String, conditionNote: String?, waterResistance: String?,
        specificationNotes: String?
    ) -> String? {
        var lines: [String] = []
        if condition != "Unknown" { lines.append("Condition: \(condition)") }
        if let note = OldRecordNotes.kept(conditionNote) { lines.append("Condition note: \(note)") }
        if let resistance = OldRecordNotes.kept(waterResistance) {
            lines.append("Water resistance: \(resistance)")
        }
        if let notes = OldRecordNotes.kept(specificationNotes) {
            lines.append("Specification notes: \(notes)")
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
