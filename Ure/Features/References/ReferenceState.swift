import Foundation
import GRDB
import Observation

@Observable
final class ReferenceState {
    private let service: ReferenceService
    private var originalDraft: ReferenceDraft?
    private var pendingNavigation: (() -> Void)?
    private var cancelNavigation: (() -> Void)?
    private(set) var references: [LibraryItem] = []
    private(set) var owner: LibraryItemOwner?
    private(set) var selectedID: UUID?
    private(set) var isLoading = true
    private(set) var isSaving = false
    private(set) var openError: String?
    private(set) var loadError: String?
    private(set) var saveError: String?
    private(set) var fieldErrors: [ReferenceField: String] = [:]
    var draft: ReferenceDraft?
    var showsUnsavedChanges = false

    init(service: ReferenceService) { self.service = service }

    var selectedReference: LibraryItem? {
        guard let owner else { return nil }
        return references.first { $0.id == selectedID && $0.belongs(to: owner) }
    }
    var hasUnsavedChanges: Bool { draft != originalDraft }
    var canSave: Bool { draft != nil && !isSaving }
    var isNavigationPending: Bool { pendingNavigation != nil }

    func records(for owner: LibraryItemOwner) -> [LibraryItem] {
        references.filter { $0.belongs(to: owner) }.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
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
            let values = try await service.coordinator.referenceValues()
            for try await records in values {
                references = records
                isLoading = false
            }
        } catch {
            if Task.isCancelled { return }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    func create(for owner: LibraryItemOwner) {
        guard !isLoading, loadError == nil else { return }
        requestNavigation {
            self.owner = owner
            self.selectedID = nil
            self.draft = ReferenceDraft()
            self.originalDraft = self.draft
            self.clearErrors()
        }
    }

    func open(_ item: LibraryItem, for owner: LibraryItemOwner) {
        guard item.belongs(to: owner) else { return }
        requestNavigation {
            self.owner = owner
            self.selectedID = item.id
            self.clearErrors()
        }
    }

    func edit() {
        guard !isSaving, draft == nil, let selectedReference else { return }
        draft = ReferenceDraft(item: selectedReference)
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
        guard !isSaving, let draft, let owner else { return false }
        isSaving = true
        clearErrors()
        defer { isSaving = false }
        do {
            let saved = try await service.save(draft, for: owner, editing: selectedID)
            if let index = references.firstIndex(where: { $0.id == saved.id }) {
                references[index] = saved
            } else {
                references.append(saved)
            }
            selectedID = saved.id
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

    func openInBrowser() {
        guard !isSaving, draft == nil, let selectedReference else { return }
        openError = nil
        do {
            try service.open(selectedReference)
        } catch {
            openError = error.localizedDescription
        }
    }

    func requestNavigation(_ action: @escaping () -> Void, onCancel: (() -> Void)? = nil) {
        guard !isSaving, pendingNavigation == nil else {
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
        openError = nil
        saveError = nil
        fieldErrors = [:]
    }

    private func clearNavigation() {
        showsUnsavedChanges = false
        pendingNavigation = nil
        cancelNavigation = nil
    }
}
