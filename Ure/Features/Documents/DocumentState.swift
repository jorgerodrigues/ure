import Foundation
import GRDB
import Observation

@Observable
final class DocumentState {
    var reader: ReferenceReader { ReferenceReader(coordinator: service.coordinator) }
    private let service: DocumentService
    private var originalDraft: DocumentDraft?
    private var pendingNavigation: (() -> Void)?
    private var cancelNavigation: (() -> Void)?
    private(set) var documents: [DocumentRecord] = []
    private(set) var owner: LibraryItemOwner?
    private(set) var selectedID: UUID?
    private(set) var isLoading = true
    private(set) var isSaving = false
    private(set) var operationError: String?
    private(set) var loadError: String?
    private(set) var fieldErrors: [ReferenceField: String] = [:]
    private(set) var saveError: String?
    private(set) var importResults: [FileImportResult<DocumentRecord>] = []
    private(set) var importOwner: LibraryItemOwner?
    private(set) var isImporting = false
    private var importTask: Task<Void, Never>?
    var draft: DocumentDraft?
    var showsUnsavedChanges = false

    init(service: DocumentService) { self.service = service }

    var selectedDocument: DocumentRecord? {
        guard let owner else { return nil }
        return documents.first { $0.id == selectedID && $0.item.belongs(to: owner) }
    }
    var hasUnsavedChanges: Bool { draft != originalDraft }
    func canSave(jobs: JobState) -> Bool {
        guard let owner else { return false }
        return draft != nil && !isSaving && !isImporting && canWrite(owner, jobs: jobs)
    }
    var isNavigationPending: Bool { pendingNavigation != nil }

    func records(for owner: LibraryItemOwner, matching query: String = "") -> [DocumentRecord] {
        documents.filter {
            $0.item.belongs(to: owner)
                && SearchKey.matches([$0.item.title, $0.item.caption], query: query)
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
            let values = try await service.coordinator.documentValues()
            for try await records in values {
                documents = records
                isLoading = false
            }
        } catch {
            if Task.isCancelled { return }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    func open(_ document: DocumentRecord, for owner: LibraryItemOwner) {
        guard document.item.belongs(to: owner) else { return }
        requestNavigation {
            self.owner = owner
            self.selectedID = document.id
            self.clearErrors()
        }
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
                if case .success(let document) = result.outcome,
                    !documents.contains(where: { $0.id == document.id })
                {
                    documents.append(document)
                }
            }
            importResults = results
            isImporting = false
            importTask = nil
        }
    }

    func cancelImport() { importTask?.cancel() }

    func openSource() {
        guard !isSaving, !isImporting, draft == nil, let selectedDocument else { return }
        operationError = nil
        do { try service.openSource(selectedDocument.item) } catch {
            operationError = error.localizedDescription
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
        guard !isSaving, !isImporting, draft == nil, let selectedDocument else { return }
        draft = DocumentDraft(item: selectedDocument.item)
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
            if let index = documents.firstIndex(where: { $0.id == saved.id }) {
                documents[index] = DocumentRecord(item: saved, asset: documents[index].asset)
            }
            self.selectedID = saved.id
            self.draft = nil
            originalDraft = nil
            return true
        } catch {
            saveError = error.localizedDescription
            if let validation = error as? ReferenceValidationError {
                fieldErrors = validation.fields
            }
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
        fieldErrors = [:]
    }

    private func clearNavigation() {
        showsUnsavedChanges = false
        pendingNavigation = nil
        cancelNavigation = nil
    }
}
