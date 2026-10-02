import Foundation

nonisolated enum NoteField: Hashable {
    case title
    case occurredAt
}

nonisolated struct NoteValidationError: LocalizedError {
    let fields: [NoteField: String]
    var errorDescription: String? { "Check the marked fields. Your draft has been kept." }
}

nonisolated struct NoteDraft: Equatable, Sendable {
    var title = ""
    var body = ""
    var kind: NoteKind = .observation
    var occurredAt: Date

    init(occurredAt: Date = Date()) { self.occurredAt = occurredAt }

    init(note: NoteRecord) {
        title = note.title
        body = note.body
        kind = note.kind
        occurredAt = note.occurredAt
    }

    func record(id: UUID, owner: NoteOwner, createdAt: Date, updatedAt: Date) throws -> NoteRecord {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [NoteField: String] = [:]
        if title.isEmpty { fields[.title] = "Enter a note title." }
        if !occurredAt.timeIntervalSince1970.isFinite {
            fields[.occurredAt] = "Enter a valid occurred date."
        }
        if !fields.isEmpty { throw NoteValidationError(fields: fields) }
        var watchID: UUID?
        var jobID: UUID?
        var caliberID: UUID?
        switch owner {
        case .watch(let id): watchID = id
        case .job(let id): jobID = id
        case .caliber(let id): caliberID = id
        }
        return NoteRecord(
            id: id, watchID: watchID, jobID: jobID, caliberID: caliberID, title: title,
            body: body, kind: kind,
            occurredAt: Date(timeIntervalSince1970: occurredAt.timeIntervalSince1970),
            createdAt: createdAt, updatedAt: updatedAt)
    }
}
