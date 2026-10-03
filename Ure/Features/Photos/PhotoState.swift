import CoreGraphics
import Foundation
import GRDB
import Observation

@Observable
final class PhotoState {
    var reader: ReferenceReader { ReferenceReader(coordinator: service.coordinator) }
    private let service: PhotoService
    private var originalDraft: PhotoDraft?
    private var pendingNavigation: (() -> Void)?
    private var cancelNavigation: (() -> Void)?
    private(set) var photos: [PhotoRecord] = []
    private(set) var owner: LibraryItemOwner?
    private(set) var selectedID: UUID?
    private(set) var isLoading = true
    private(set) var isSaving = false
    private(set) var operationError: String?
    private(set) var loadError: String?
    private(set) var saveError: String?
    private(set) var importResults: [FileImportResult<PhotoRecord>] = []
    private(set) var importOwner: LibraryItemOwner?
    private(set) var isImporting = false
    private var importTask: Task<Void, Never>?
    var stageFilter: PhotoStage?
    var draft: PhotoDraft?
    var showsRemovalConfirmation = false
    private var removalID: UUID?
    var showsUnsavedChanges = false

    init(service: PhotoService) { self.service = service }

    var selectedPhoto: PhotoRecord? {
        guard let owner else { return nil }
        return photos.first { $0.id == selectedID && $0.item.belongs(to: owner) }
    }
    var hasUnsavedChanges: Bool { draft != originalDraft }
    func canSave(jobs: JobState) -> Bool {
        guard let owner else { return false }
        return draft != nil && !isSaving && !isImporting && canWrite(owner, jobs: jobs)
    }
    var isNavigationPending: Bool { pendingNavigation != nil }

    func records(for owner: LibraryItemOwner, filtered: Bool = true, matching query: String = "")
        -> [PhotoRecord]
    {
        photos.filter {
            $0.item.belongs(to: owner)
                && SearchKey.matches([$0.item.title, $0.item.caption], query: query)
                && (!filtered || stageFilter == nil || $0.item.photoStage == stageFilter)
        }.sorted { lhs, rhs in
            if lhs.item.createdAt != rhs.item.createdAt {
                return lhs.item.createdAt > rhs.item.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    func isPresenting(for owner: LibraryItemOwner) -> Bool {
        self.owner == owner && (selectedID != nil || draft != nil)
    }

    func canWrite(_ owner: LibraryItemOwner, jobs: JobState) -> Bool {
        if case .job(let id) = owner {
            return jobs.loadError == nil && !jobs.isLoading
                && jobs.jobs.contains { $0.id == id && $0.stage.isOpen }
        }
        return true
    }

    func observe() async {
        isLoading = true
        loadError = nil
        do {
            let values = try await service.coordinator.photoValues()
            for try await records in values {
                photos = records
                if let selectedID, draft == nil, !photos.contains(where: { $0.id == selectedID }) {
                    self.selectedID = nil
                    self.owner = nil
                    showsRemovalConfirmation = false
                    removalID = nil
                }
                isLoading = false
            }
        } catch {
            if Task.isCancelled { return }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    func open(_ photo: PhotoRecord, for owner: LibraryItemOwner) {
        guard photo.item.belongs(to: owner) else { return }
        requestNavigation {
            self.owner = owner
            self.selectedID = photo.id
            self.clearErrors()
        }
    }

    func moveSelection(by offset: Int) {
        guard !isSaving, !isImporting, draft == nil else { return }
        guard let nextID = adjacentPhotoID(by: offset) else { return }
        self.selectedID = nextID
        clearErrors()
    }

    func canMove(by offset: Int) -> Bool { adjacentPhotoID(by: offset) != nil }

    private func adjacentPhotoID(by offset: Int) -> UUID? {
        guard let owner, let selectedID, offset == -1 || offset == 1 else { return nil }
        let records = records(for: owner, filtered: false)
        guard let index = records.firstIndex(where: { $0.id == selectedID }) else { return nil }
        var next = index + offset
        while records.indices.contains(next) {
            let photo = records[next]
            if stageFilter == nil || photo.item.photoStage == stageFilter { return photo.id }
            next += offset
        }
        return nil
    }

    func importFiles(_ sources: [URL], for owner: LibraryItemOwner) {
        guard !isImporting, !isSaving, draft == nil else { return }
        isImporting = true
        importOwner = owner
        importResults = []
        operationError = nil
        importTask = Task {
            let results = await service.importFiles(sources, for: owner)
            for result in results {
                if case .success(let photo) = result.outcome,
                    !photos.contains(where: { $0.id == photo.id })
                {
                    photos.append(photo)
                }
            }
            importResults = results
            isImporting = false
            importTask = nil
        }
    }

    func cancelImport() { importTask?.cancel() }

    func thumbnail(for photoID: UUID?) -> PhotoRecord? {
        photos.first { $0.id == photoID }
    }

    func image(for assetID: UUID, thumbnail: Bool) async throws -> CGImage {
        try await service.image(for: assetID, thumbnail: thumbnail)
    }

    func setCover(_ photoID: UUID?, for watchID: UUID) {
        guard !isSaving, !isImporting else { return }
        isSaving = true
        operationError = nil
        Task {
            defer { isSaving = false }
            do { _ = try await service.setCover(photoID, for: watchID) } catch {
                operationError = error.localizedDescription
            }
        }
    }

    func export(_ assetID: UUID, to destination: URL) {
        guard !isSaving, !isImporting else { return }
        isSaving = true
        operationError = nil
        Task {
            defer { isSaving = false }
            do { try await service.export(assetID, to: destination) } catch {
                operationError = error.localizedDescription
            }
        }
    }

    func edit() {
        guard !isSaving, !isImporting, draft == nil, let selectedPhoto else { return }
        draft = PhotoDraft(item: selectedPhoto.item)
        originalDraft = draft
        clearErrors()
    }

    func close() {
        requestNavigation {
            self.owner = nil
            self.selectedID = nil
        }
    }

    func cancel() {
        guard !isSaving else { return }
        showsRemovalConfirmation = false
        removalID = nil
        draft = nil
        originalDraft = nil
        clearErrors()
        if selectedID == nil { owner = nil }
    }

    @discardableResult
    func save() async -> Bool {
        guard !isSaving, !isImporting, let draft, let owner, let selectedID else { return false }
        isSaving = true
        clearErrors()
        defer { isSaving = false }
        do {
            let saved = try await service.save(draft, for: owner, editing: selectedID)
            if let index = photos.firstIndex(where: { $0.id == saved.id }) {
                photos[index] = PhotoRecord(item: saved, asset: photos[index].asset)
            }
            self.selectedID = saved.id
            self.draft = nil
            originalDraft = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    func requestRemoval() {
        guard !isSaving, !isImporting, draft == nil, !isLoading, loadError == nil,
            let record = selectedPhoto
        else { return }
        removalID = record.id
        showsRemovalConfirmation = true
    }

    func removeCommand() { Task { await remove() } }

    @discardableResult
    func remove() async -> Bool {
        guard !isSaving, !isImporting, draft == nil, let id = removalID,
            selectedID == id, let owner
        else { return false }
        isSaving = true
        showsRemovalConfirmation = false
        clearErrors()
        defer { isSaving = false; removalID = nil }
        do {
            try await ChildRemovalService(coordinator: service.coordinator).removeItem(
                id, for: owner, kind: .photo)
            photos.removeAll { $0.id == id }
            selectedID = nil
            self.owner = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    func saveCommand() { Task { await save() } }

    func requestNavigation(_ action: @escaping () -> Void, onCancel: (() -> Void)? = nil) {
        guard !isSaving, !isImporting, pendingNavigation == nil else {
            onCancel?()
            return
        }
        if !hasUnsavedChanges {
            cancel()
            action()
            return
        }
        pendingNavigation = action
        cancelNavigation = onCancel
        showsUnsavedChanges = true
    }

    func stay() {
        let cancel = cancelNavigation
        clearNavigation()
        cancel?()
    }

    func discardAndContinue() {
        let action = pendingNavigation
        clearNavigation()
        cancel()
        action?()
    }

    func saveAndContinue() async {
        guard !isSaving else { return }
        if await save() {
            let action = pendingNavigation
            clearNavigation()
            action?()
        } else {
            stay()
        }
    }

    private func clearErrors() {
        operationError = nil
        saveError = nil
    }

    private func clearNavigation() {
        showsUnsavedChanges = false
        pendingNavigation = nil
        cancelNavigation = nil
    }
}
