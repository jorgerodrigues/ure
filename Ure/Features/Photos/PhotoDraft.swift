import Foundation

nonisolated struct PhotoDraft: Equatable, Sendable {
    var title: String
    var caption: String
    var stage: PhotoStage

    init(item: LibraryItem) {
        title = item.title
        caption = item.caption ?? ""
        stage = item.photoStage ?? .unclassified
    }

    func applying(to item: LibraryItem, updatedAt: Date) throws -> LibraryItem {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw PhotoError.invalidTitle }
        var record = LibraryItem(
            id: item.id, watchID: item.watchID, jobID: item.jobID, caliberID: item.caliberID,
            kind: .photo, title: title, sourceURL: item.sourceURL,
            sourceDescription: item.sourceDescription, notes: item.notes,
            createdAt: item.createdAt, updatedAt: updatedAt)
        record.fileAssetID = item.fileAssetID
        record.photoStage = stage
        record.caption = caption
        return record
    }
}
