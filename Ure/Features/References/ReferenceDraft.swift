import Foundation

nonisolated enum ReferenceField: Hashable {
    case title
    case sourceURL
}

nonisolated struct ReferenceValidationError: LocalizedError {
    let fields: [ReferenceField: String]
    var errorDescription: String? { "Check the marked fields. Your draft has been kept." }
}

nonisolated struct ReferenceDraft: Equatable, Sendable {
    var title = ""
    var sourceURL = ""
    var sourceDescription = ""
    var notes = ""

    init() {}

    init(item: LibraryItem) {
        title = item.title
        sourceURL = item.sourceURL
        sourceDescription = item.sourceDescription
        notes = item.notes
    }

    static func parsedURL(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
            let url = URL(string: text, encodingInvalidCharacters: false),
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    func record(id: UUID, owner: LibraryItemOwner, createdAt: Date, updatedAt: Date) throws
        -> LibraryItem
    {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceURL = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [ReferenceField: String] = [:]
        if title.isEmpty { fields[.title] = "Enter a reference title." }
        if Self.parsedURL(sourceURL) == nil {
            fields[.sourceURL] = "Enter a complete HTTP or HTTPS URL with a host."
        }
        if !fields.isEmpty { throw ReferenceValidationError(fields: fields) }
        var watchID: UUID?
        var jobID: UUID?
        var caliberID: UUID?
        switch owner {
        case .watch(let id): watchID = id
        case .job(let id): jobID = id
        case .caliber(let id): caliberID = id
        }
        return LibraryItem(
            id: id, watchID: watchID, jobID: jobID, caliberID: caliberID, kind: .link,
            title: title, sourceURL: sourceURL, sourceDescription: sourceDescription, notes: notes,
            createdAt: createdAt, updatedAt: updatedAt)
    }
}
