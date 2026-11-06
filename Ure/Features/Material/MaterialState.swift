import CoreGraphics
import Foundation
import GRDB
import Observation

// The material a viewer shows, and the record page it was opened from. Caliber material opens
// from its watches' and jobs' pages too.
nonisolated struct MaterialPresentation: Equatable, Sendable {
    let itemID: UUID
    let page: LibraryItemOwner
}

// The material of every record: photos, PDFs and links. Every change, such as an import, a new
// title or a removal, goes through the library's edit queue, in the order you made it.
@Observable
final class MaterialState {
    var reader: ReferenceReader { ReferenceReader(coordinator: service.coordinator) }
    private let service: MaterialService
    let queue: EditQueue
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    private(set) var records: [MaterialRecord] = []
    private(set) var isLoading = true
    private(set) var loadError: String?
    private(set) var titleFields: [UUID: AutosaveField] = [:]
    // Problems that are not edits, such as a link that does not read or a file that won't open.
    private var problems: [LibraryItemOwner: String] = [:]
    private(set) var presented: MaterialPresentation?
    private(set) var isExporting = false
    private(set) var importOwner: LibraryItemOwner?
    private(set) var importResults: [FileImportResult<MaterialRecord>] = []
    private var importTicket: EditTicket?

    init(
        service: MaterialService, queue: EditQueue,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.service = service
        self.queue = queue
        self.pause = pause
        queue.listen { [weak self] change, byUndo in self?.receive(change, byUndo: byUndo) }
    }

    // A material change is still saving, or a file is being copied out. Material buttons wait.
    var isBusy: Bool { queue.isBusyWithMaterial || isExporting }
    var isImporting: Bool { importTicket != nil }

    // What went wrong on a record's page: a change that did not save, or another problem.
    func error(for page: LibraryItemOwner) -> String? {
        problems[page] ?? queue.failure(in: .material(page))
    }

    // Material in the order it was added.
    func records(for owner: LibraryItemOwner) -> [MaterialRecord] {
        records.filter { $0.item.belongs(to: owner) }.sorted { lhs, rhs in
            if lhs.item.createdAt != rhs.item.createdAt {
                return lhs.item.createdAt < rhs.item.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    func titleField(for id: UUID) -> AutosaveField? { titleFields[id] }

    func photo(_ id: UUID?) -> MaterialRecord? {
        records.first { $0.id == id && $0.item.kind == .photo }
    }

    func observe() async {
        isLoading = true
        loadError = nil
        do {
            for try await values in try await queue.coordinator.materialValues() {
                apply(values)
                isLoading = false
            }
        } catch {
            if Task.isCancelled { return }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    private func apply(_ values: [MaterialRecord]) {
        records = values
        for record in values { adoptTitle(of: record) }
        if let presented, !values.contains(where: { $0.id == presented.itemID }) {
            self.presented = nil
        }
    }

    private func receive(_ change: LibraryChange, byUndo: Bool) {
        switch change {
        case .material(let record):
            insert(record)
        case .materialItem(let item):
            if let index = records.firstIndex(where: { $0.id == item.id }) {
                records[index] = MaterialRecord(item: item, asset: records[index].asset)
            }
            titleFields[item.id]?.refresh(item.title, force: byUndo)
        case .materialRemoved(let id):
            records.removeAll { $0.id == id }
            if presented?.itemID == id { presented = nil }
        case .imported(_, let results):
            for result in results {
                if case .success(let record) = result.outcome { insert(record) }
            }
            importResults = results
        default:
            break
        }
    }

    // Keeps one autosave field per material, made the first time the material shows.
    private func adoptTitle(of record: MaterialRecord) {
        if let field = titleFields[record.id] {
            field.refresh(record.item.title)
            return
        }
        guard let owner = record.item.owner else { return }
        let id = record.id
        titleFields[id] = AutosaveField(
            text: record.item.title, actionName: "Rename", queue: queue,
            scope: .material(owner), edit: { .material(.rename(id, $0, owner)) }, pause: pause,
            accepts: Self.isTitle, putsBackRefusedText: true)
    }

    private static func isTitle(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Leaving a blank title puts back the title it had when editing began.
    func endEditingTitle(_ field: AutosaveField, undoManager: UndoManager?) {
        if !Self.isTitle(field.text) { field.revert(undoManager: undoManager) }
        field.endEditing()
    }

    func importFiles(_ sources: [URL], for owner: LibraryItemOwner) {
        guard !isImporting, !sources.isEmpty else { return }
        importOwner = owner
        importResults = []
        problems[owner] = nil
        importTicket = queue.submit(.material(.importFiles(sources, owner)), in: .material(owner)) {
            [weak self] result in
            guard let self else { return }
            importTicket = nil
            if result.error is CancellationError {
                importResults = sources.map { source in
                    FileImportResult(source: source, outcome: .failure(FileImportError.cancelled))
                }
            }
        }
    }

    func cancelImport() {
        if let importTicket { queue.cancel(importTicket) }
    }

    func reportError(_ message: String, on page: LibraryItemOwner) { problems[page] = message }

    // Dropped files import. Dropped web addresses become links.
    func add(_ urls: [URL], for owner: LibraryItemOwner) {
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { importFiles(files, for: owner) }
        for url in urls where !url.isFileURL {
            addLink(url.absoluteString, for: owner)
        }
    }

    // A pasted web address becomes a link. Nil when the text is not one.
    @discardableResult
    func paste(_ text: String?, for owner: LibraryItemOwner) -> EditTicket? {
        addLink(text ?? "", for: owner)
    }

    @discardableResult
    private func addLink(_ text: String, for owner: LibraryItemOwner) -> EditTicket? {
        problems[owner] = nil
        do {
            let url = try WebLink.parse(text)
            return queue.submit(.material(.addLink(url, owner)), in: .material(owner))
        } catch {
            problems[owner] = error.localizedDescription
            return nil
        }
    }

    // Shows material that the library has not reported yet. Material it already reported keeps
    // its current title, which may have changed since.
    private func insert(_ record: MaterialRecord) {
        guard !records.contains(where: { $0.id == record.id }) else { return }
        records.append(record)
        adoptTitle(of: record)
    }

    // Links open in the browser. Photos and PDFs open in the viewer on the page they came from.
    func open(_ record: MaterialRecord, on page: LibraryItemOwner) {
        problems[page] = nil
        guard record.item.kind != .link else {
            do { try service.openLink(record.item) } catch {
                problems[page] = error.localizedDescription
            }
            return
        }
        presented = MaterialPresentation(itemID: record.id, page: page)
    }

    var presentedRecord: MaterialRecord? {
        guard let presented else { return nil }
        return records.first { $0.id == presented.itemID }
    }

    func isPresenting(on page: LibraryItemOwner) -> Bool {
        presented?.page == page && presentedRecord != nil
    }

    func close() { presented = nil }

    func canMove(by offset: Int) -> Bool { adjacentPhoto(by: offset) != nil }

    func moveSelection(by offset: Int) {
        guard let presented, let next = adjacentPhoto(by: offset) else { return }
        self.presented = MaterialPresentation(itemID: next.id, page: presented.page)
    }

    private func adjacentPhoto(by offset: Int) -> MaterialRecord? {
        guard offset == -1 || offset == 1, let record = presentedRecord,
            record.item.kind == .photo, let owner = record.item.owner
        else { return nil }
        let photos = records(for: owner).filter { $0.item.kind == .photo }
        guard let index = photos.firstIndex(where: { $0.id == record.id }) else { return nil }
        let next = index + offset
        return photos.indices.contains(next) ? photos[next] : nil
    }

    func image(for assetID: UUID, thumbnail: Bool) async throws -> CGImage {
        try await service.image(for: assetID, thumbnail: thumbnail)
    }

    func export(_ assetID: UUID, to destination: URL, from page: LibraryItemOwner) {
        guard !isExporting else { return }
        isExporting = true
        problems[page] = nil
        Task {
            defer { isExporting = false }
            do { try await service.export(assetID, to: destination) } catch {
                problems[page] = error.localizedDescription
            }
        }
    }

    @discardableResult
    func setCover(_ photoID: UUID?, for watchID: UUID) -> EditTicket? {
        guard !queue.isBusyWithMaterial else { return nil }
        return queue.submit(
            .material(.setCover(photoID, watch: watchID)), in: .material(.watch(watchID)))
    }

    // Material can be removed only on its own page, not where it shows from its caliber.
    func canRemove(_ record: MaterialRecord, on page: LibraryItemOwner) -> Bool {
        record.item.belongs(to: page) && !queue.isBusyWithMaterial
    }

    // Removes material. Undo puts it back, and Redo removes it again. A title still being typed
    // saves first, so Undo brings the material back with it.
    @discardableResult
    func remove(_ record: MaterialRecord, on page: LibraryItemOwner, undoManager: UndoManager?)
        -> EditTicket?
    {
        guard canRemove(record, on: page) else { return nil }
        problems[page] = nil
        return queue.submit(
            .material(.remove(record.id, page)), in: .material(page),
            undo: "Remove \(record.item.kind.title)", undoManager: undoManager)
    }
}
