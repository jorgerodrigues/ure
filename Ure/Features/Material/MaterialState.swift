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

@Observable
final class MaterialState {
    var reader: ReferenceReader { ReferenceReader(coordinator: service.coordinator) }
    private let service: MaterialService
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    private(set) var records: [MaterialRecord] = []
    private(set) var isLoading = true
    private(set) var loadError: String?
    private(set) var titleFields: [UUID: AutosaveField] = [:]
    private(set) var errors: [LibraryItemOwner: String] = [:]
    private(set) var presented: MaterialPresentation?
    private(set) var isChanging = false
    private(set) var pendingChanges = 0
    private(set) var isExporting = false
    private(set) var importOwner: LibraryItemOwner?
    private(set) var importResults: [FileImportResult<MaterialRecord>] = []
    private(set) var isImporting = false
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var changeTask: Task<Void, Never>?
    @ObservationIgnored private weak var undoManager: UndoManager?

    init(
        service: MaterialService,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.service = service
        self.pause = pause
    }

    var isBusy: Bool { isChanging || pendingChanges > 0 || isExporting || isImporting }
    var hasUnsavedTitles: Bool { titleFields.values.contains { $0.hasUnsavedChanges } }

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
            for try await values in try await service.coordinator.materialValues() {
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

    // Keeps one autosave field per material. A field stays after its material is removed, so
    // Undo of a rename still works once Undo brings the material back.
    private func adoptTitle(of record: MaterialRecord) {
        if let field = titleFields[record.id] {
            field.refresh(record.item.title)
            return
        }
        guard let owner = record.item.owner else { return }
        let id = record.id
        titleFields[id] = AutosaveField(
            text: record.item.title, actionName: "Rename",
            save: { [service] title in try await service.rename(id, to: title, for: owner) },
            pause: pause)
    }

    // Leaving a blank title puts back the title it had when editing began.
    func endEditingTitle(_ field: AutosaveField, undoManager: UndoManager?) {
        if field.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            field.revert(undoManager: undoManager)
        }
        field.endEditing()
    }

    func saveTitlesNow() {
        for field in titleFields.values where field.hasUnsavedChanges { field.saveNow() }
    }

    func saveAllTitles() async -> Bool {
        var succeeded = true
        for field in titleFields.values where field.hasUnsavedChanges {
            if await !field.flush() { succeeded = false }
        }
        return succeeded
    }

    func discardUndo() {
        for field in titleFields.values { field.discardUndo() }
        undoManager?.removeAllActions(withTarget: self)
    }

    func importFiles(_ sources: [URL], for owner: LibraryItemOwner) {
        guard !isImporting, !sources.isEmpty else { return }
        isImporting = true
        importOwner = owner
        importResults = []
        errors[owner] = nil
        importTask = Task {
            let results = await service.importFiles(sources, for: owner)
            for result in results {
                if case .success(let record) = result.outcome { insert(record) }
            }
            importResults = results
            isImporting = false
            importTask = nil
        }
    }

    func cancelImport() { importTask?.cancel() }

    func reportError(_ message: String, on page: LibraryItemOwner) { errors[page] = message }

    // Dropped files import. Dropped web addresses become links.
    func add(_ urls: [URL], for owner: LibraryItemOwner) async {
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { importFiles(files, for: owner) }
        for url in urls where !url.isFileURL {
            await addLink(url.absoluteString, for: owner)
        }
    }

    @discardableResult
    func paste(_ text: String?, for owner: LibraryItemOwner) async -> Bool {
        await addLink(text ?? "", for: owner)
    }

    @discardableResult
    private func addLink(_ text: String, for owner: LibraryItemOwner) async -> Bool {
        errors[owner] = nil
        do {
            let url = try WebLink.parse(text)
            isChanging = true
            defer { isChanging = false }
            let item = try await service.addLink(url, for: owner)
            insert(MaterialRecord(item: item, asset: nil))
            return true
        } catch {
            errors[owner] = error.localizedDescription
            return false
        }
    }

    private func insert(_ record: MaterialRecord) {
        if !records.contains(where: { $0.id == record.id }) { records.append(record) }
        adoptTitle(of: record)
    }

    // Links open in the browser. Photos and PDFs open in the viewer on the page they came from.
    func open(_ record: MaterialRecord, on page: LibraryItemOwner) {
        errors[page] = nil
        guard record.item.kind != .link else {
            do { try service.openLink(record.item) } catch {
                errors[page] = error.localizedDescription
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
        errors[page] = nil
        Task {
            defer { isExporting = false }
            do { try await service.export(assetID, to: destination) } catch {
                errors[page] = error.localizedDescription
            }
        }
    }

    func setCover(_ photoID: UUID?, for watchID: UUID) {
        guard !isChanging else { return }
        isChanging = true
        errors[.watch(watchID)] = nil
        Task {
            defer { isChanging = false }
            do { try await service.setCover(photoID, for: watchID) } catch {
                errors[.watch(watchID)] = error.localizedDescription
            }
        }
    }

    // Material can be removed only on its own page, not where it shows from its caliber.
    func canRemove(_ record: MaterialRecord, on page: LibraryItemOwner) -> Bool {
        record.item.belongs(to: page) && !isChanging
    }

    // Removes material. Undo puts it back, and Redo removes it again.
    @discardableResult
    func remove(_ record: MaterialRecord, on page: LibraryItemOwner, undoManager: UndoManager?)
        async -> Bool
    {
        guard canRemove(record, on: page) else { return false }
        isChanging = true
        defer { isChanging = false }
        errors[page] = nil
        await changeTask?.value
        do {
            let removed = try await service.remove(record.id, from: page)
            records.removeAll { $0.id == record.id }
            if presented?.itemID == record.id { presented = nil }
            registerRestore(removed, page: page, undoManager: undoManager)
            return true
        } catch {
            errors[page] = error.localizedDescription
            return false
        }
    }

    // Undo and Redo register their opposite while they run, then save in order.
    private func registerRestore(
        _ removed: RemovedMaterial, page: LibraryItemOwner, undoManager: UndoManager?
    ) {
        guard let undoManager else { return }
        self.undoManager = undoManager
        undoManager.registerUndo(withTarget: self) { [weak undoManager] state in
            MainActor.assumeIsolated {
                state.restore(removed, page: page, undoManager: undoManager)
            }
        }
        undoManager.setActionName("Remove \(removed.item.kind.title)")
    }

    private func registerRemoval(
        _ removed: RemovedMaterial, page: LibraryItemOwner, undoManager: UndoManager?
    ) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { [weak undoManager] state in
            MainActor.assumeIsolated {
                state.removeAgain(removed, page: page, undoManager: undoManager)
            }
        }
        undoManager.setActionName("Remove \(removed.item.kind.title)")
    }

    private func restore(
        _ removed: RemovedMaterial, page: LibraryItemOwner, undoManager: UndoManager?
    ) {
        registerRemoval(removed, page: page, undoManager: undoManager)
        enqueue(page: page) { [service] in try await service.restore(removed) }
    }

    private func removeAgain(
        _ removed: RemovedMaterial, page: LibraryItemOwner, undoManager: UndoManager?
    ) {
        registerRestore(removed, page: page, undoManager: undoManager)
        if presented?.itemID == removed.item.id { presented = nil }
        enqueue(page: page) { [service] in
            _ = try await service.remove(removed.item.id, from: page)
        }
    }

    private func enqueue(
        page: LibraryItemOwner, _ change: @escaping @Sendable () async throws -> Void
    ) {
        let previous = changeTask
        errors[page] = nil
        pendingChanges += 1
        changeTask = Task {
            await previous?.value
            do { try await change() } catch {
                errors[page] = error.localizedDescription
            }
            pendingChanges -= 1
        }
    }

    // Waits for Undo and Redo changes that are still saving.
    func waitForChanges() async { await changeTask?.value }
}
