import Foundation
import GRDB
import Observation

@Observable
final class WatchState {
    private let service: WatchService
    private var originalDraft: WatchDraft?
    private var pendingNavigation: (() -> Void)?
    private var cancelNavigation: (() -> Void)?
    private(set) var watches: [WatchRecord] = []
    private(set) var selectedID: UUID?
    private(set) var isLoading = true
    private(set) var isSaving = false
    private(set) var loadError: String?
    private(set) var saveError: String?
    private(set) var fieldErrors: [WatchField: String] = [:]
    var draft: WatchDraft?
    var searchText = ""
    var showsUnsavedChanges = false

    init(service: WatchService) {
        self.service = service
    }

    var selectedWatch: WatchRecord? { watches.first { $0.id == selectedID } }
    var hasUnsavedChanges: Bool { draft != originalDraft }
    var canSave: Bool { draft != nil && !isSaving }
    var isNavigationPending: Bool { pendingNavigation != nil }

    var filteredWatches: [WatchRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return watches }
        return watches.filter { watch in
            [watch.name, watch.brand, watch.model, watch.caseReference, watch.serial]
                .compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    func observe() async {
        isLoading = true
        loadError = nil
        do {
            let values = try await service.coordinator.watchValues()
            for try await records in values {
                watches = records
                isLoading = false
            }
        } catch {
            if Task.isCancelled { return }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    func select(_ id: UUID?) {
        guard id != selectedID else { return }
        requestNavigation { self.selectedID = id }
    }

    func create() {
        requestNavigation {
            self.selectedID = nil
            self.draft = WatchDraft()
            self.originalDraft = self.draft
        }
    }

    func edit() {
        guard !isSaving, let selectedWatch else { return }
        draft = WatchDraft(watch: selectedWatch)
        originalDraft = draft
        clearErrors()
    }

    func cancel() {
        guard !isSaving else { return }
        draft = nil
        originalDraft = nil
        clearErrors()
    }

    @discardableResult
    func save() async -> Bool {
        guard !isSaving, let draft else { return false }
        isSaving = true
        clearErrors()
        defer { isSaving = false }
        do {
            let saved = try await service.save(draft, editing: selectedID)
            if let index = watches.firstIndex(where: { $0.id == saved.id }) {
                watches[index] = saved
            } else {
                watches.append(saved)
            }
            selectedID = saved.id
            self.draft = nil
            originalDraft = nil
            return true
        } catch {
            saveError = error.localizedDescription
            if let validation = error as? WatchValidationError {
                fieldErrors = validation.fields
            }
            return false
        }
    }

    func saveCommand() {
        Task { await save() }
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

    func saveAndContinueCommand() {
        Task { await saveAndContinue() }
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
        saveError = nil
        fieldErrors = [:]
    }

    private func clearNavigation() {
        showsUnsavedChanges = false
        pendingNavigation = nil
        cancelNavigation = nil
    }
}
