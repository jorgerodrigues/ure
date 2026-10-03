import Foundation
import GRDB
import Observation

@Observable
final class CaliberState {
    private let service: CaliberService
    private var originalDraft: CaliberDraft?
    private var pendingNavigation: (() -> Void)?
    private var cancelNavigation: (() -> Void)?
    private(set) var calibers: [CaliberRecord] = []
    private(set) var selectedID: UUID?
    private(set) var isLoading = true
    private(set) var isSaving = false
    private(set) var loadError: String?
    private(set) var saveError: String?
    private(set) var fieldErrors: [CaliberField: String] = [:]
    var draft: CaliberDraft?
    var searchText = ""
    var showsUnsavedChanges = false

    init(service: CaliberService) {
        self.service = service
    }

    var selectedCaliber: CaliberRecord? { calibers.first { $0.id == selectedID } }
    var hasUnsavedChanges: Bool { draft != originalDraft }
    var canSave: Bool { draft != nil && !isSaving }
    var isNavigationPending: Bool { pendingNavigation != nil }

    var filteredCalibers: [CaliberRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return calibers }
        return calibers.filter { caliber in
            SearchKey.matches(
                [caliber.designation, caliber.manufacturer, caliber.variant], query: query)
        }
    }

    func observe() async {
        isLoading = true
        loadError = nil
        do {
            let values = try await service.coordinator.caliberValues()
            for try await records in values {
                calibers = records
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
            self.draft = CaliberDraft()
            self.originalDraft = self.draft
        }
    }

    func edit() {
        guard !isSaving, let selectedCaliber else { return }
        draft = CaliberDraft(caliber: selectedCaliber)
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
            if let index = calibers.firstIndex(where: { $0.id == saved.id }) {
                calibers[index] = saved
            } else {
                calibers.append(saved)
            }
            selectedID = saved.id
            self.draft = nil
            originalDraft = nil
            return true
        } catch {
            saveError = error.localizedDescription
            if let validation = error as? CaliberValidationError {
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
