import Foundation

nonisolated struct DocumentDraft: Equatable, Sendable {
    var title: String
    var sourceURL: String
    var sourceDescription: String
    var notes: String

    init(item: LibraryItem) {
        title = item.title
        sourceURL = item.sourceURL
        sourceDescription = item.sourceDescription
        notes = item.notes
    }

    func applying(to item: LibraryItem, updatedAt: Date) throws -> LibraryItem {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceURL = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [ReferenceField: String] = [:]
        if title.isEmpty { fields[.title] = "Enter a document title." }
        if !sourceURL.isEmpty, ReferenceDraft.parsedURL(sourceURL) == nil {
            fields[.sourceURL] =
                "Enter a complete HTTP or HTTPS URL with a host, or leave it empty."
        }
        if !fields.isEmpty { throw ReferenceValidationError(fields: fields) }
        var record = LibraryItem(
            id: item.id, watchID: item.watchID, jobID: item.jobID, caliberID: item.caliberID,
            kind: .document, title: title, sourceURL: sourceURL,
            sourceDescription: sourceDescription, notes: notes, createdAt: item.createdAt,
            updatedAt: updatedAt)
        record.fileAssetID = item.fileAssetID
        return record
    }
}
