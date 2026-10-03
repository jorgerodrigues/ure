import Foundation
import GRDB
import Observation

@Observable
final class PartState {
    private let service: PartService
    private var originalDraft: PartDraft?
    private var pendingNavigation: (() -> Void)?
    private var cancelNavigation: (() -> Void)?
    private(set) var parts: [PartRequirement] = []
    private(set) var jobID: UUID?
    private(set) var selectedID: UUID?
    private(set) var isLoading = true
    private(set) var isSaving = false
    private(set) var loadError: String?
    private(set) var saveError: String?
    private(set) var openError: String?
    private(set) var fieldErrors: [PartField: String] = [:]
    var draft: PartDraft?
    var showsUnsavedChanges = false
    var linkToRemove: UUID?

    init(service: PartService) { self.service = service }

    var selectedPart: PartRequirement? {
        parts.first { $0.id == selectedID && $0.record.jobID == jobID }
    }
    var hasUnsavedChanges: Bool { draft != originalDraft }
    var isNavigationPending: Bool { pendingNavigation != nil }

    func records(for jobID: UUID, matching query: String = "") -> [PartRequirement] {
        parts.filter {
            $0.record.jobID == jobID
                && SearchKey.matches(
                    [
                        $0.record.description, $0.record.manufacturerReference,
                        $0.record.supplierSnapshot?.supplierStockCode,
                    ] + $0.links.map(\.supplierStockCode), query: query)
        }
    }

    func isPresenting(for jobID: UUID) -> Bool {
        self.jobID == jobID && (selectedID != nil || draft != nil)
    }

    func canWrite(_ jobID: UUID, jobs: JobState) -> Bool {
        !isLoading && loadError == nil && !jobs.isLoading && jobs.loadError == nil
            && jobs.jobs.contains { $0.id == jobID && $0.stage.isOpen }
    }

    func canSave(jobs: JobState) -> Bool {
        guard let jobID else { return false }
        return draft != nil && !isSaving && canWrite(jobID, jobs: jobs)
    }

    func observe() async {
        isLoading = true
        loadError = nil
        do {
            let values = try await service.coordinator.partValues()
            for try await records in values {
                parts = records
                isLoading = false
            }
        } catch {
            if Task.isCancelled { return }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    func create(for jobID: UUID, jobs: JobState) {
        guard canWrite(jobID, jobs: jobs) else { return }
        requestNavigation {
            self.jobID = jobID
            self.selectedID = nil
            self.draft = PartDraft()
            self.originalDraft = self.draft
            self.clearErrors()
        }
    }

    func open(_ part: PartRequirement, for jobID: UUID) {
        guard part.record.jobID == jobID else { return }
        requestNavigation {
            self.jobID = jobID
            self.selectedID = part.id
            self.clearErrors()
        }
    }

    func edit(jobs: JobState) {
        guard !isSaving, draft == nil, let selectedPart,
            canWrite(selectedPart.record.jobID, jobs: jobs)
        else { return }
        draft = PartDraft(part: selectedPart)
        originalDraft = draft
        clearErrors()
    }

    func close() {
        requestNavigation {
            self.jobID = nil
            self.selectedID = nil
        }
    }

    func cancel() {
        guard !isSaving else { return }
        draft = nil
        originalDraft = nil
        clearErrors()
        if selectedID == nil { jobID = nil }
    }

    @discardableResult
    func save() async -> Bool {
        guard !isSaving, let draft, let jobID else { return false }
        isSaving = true
        clearErrors()
        defer { isSaving = false }
        do {
            let saved = try await service.save(draft, for: jobID, editing: selectedID)
            if let index = parts.firstIndex(where: { $0.id == saved.id }) {
                parts[index] = saved
            } else {
                parts.append(saved)
            }
            selectedID = saved.id
            self.draft = nil
            originalDraft = nil
            return true
        } catch {
            saveError = error.localizedDescription
            if let validation = error as? PartValidationError { fieldErrors = validation.fields }
            return false
        }
    }

    func addLink() {
        guard !isSaving, draft != nil else { return }
        draft?.links.append(PartLinkDraft())
    }

    func setStatus(_ value: PartStatus) {
        guard !isSaving, draft != nil else { return }
        if selectedID == nil && value != .needed && value != .arrived { return }
        draft?.status = value
        draft?.confirmsOnHand = false
    }

    func confirmOnHand(_ value: Bool) {
        guard !isSaving, draft != nil else { return }
        draft?.confirmsOnHand = value
    }

    func setLinkURL(_ url: String, id: UUID) {
        setLinkField(url, id: id, keyPath: \.url)
    }

    func setLinkField(_ value: String, id: UUID, keyPath: WritableKeyPath<PartLinkDraft, String>) {
        guard !isSaving, let index = draft?.links.firstIndex(where: { $0.id == id }) else { return }
        draft?.links[index][keyPath: keyPath] = value
    }

    func selectLink(_ id: UUID?) {
        guard !isSaving, draft != nil else { return }
        if let id, draft?.links.contains(where: { $0.id == id }) != true { return }
        draft?.selectedLinkID = id
    }

    func removeLink(_ id: UUID) {
        guard !isSaving else { return }
        if originalDraft?.links.contains(where: { $0.id == id }) == true {
            linkToRemove = id
        } else {
            removeDraftLink(id)
        }
    }

    func confirmRemoveLink() {
        guard !isSaving, let id = linkToRemove else { return }
        removeDraftLink(id)
        linkToRemove = nil
    }

    private func removeDraftLink(_ id: UUID) {
        draft?.links.removeAll { $0.id == id }
        if draft?.selectedLinkID == id { draft?.selectedLinkID = nil }
    }

    func openLink(_ link: PartLink) {
        guard !isSaving, draft == nil, selectedPart?.links.contains(link) == true else { return }
        openError = nil
        do { try service.open(link) } catch { openError = error.localizedDescription }
    }

    func saveCommand() { Task { await save() } }

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
        openError = nil
        fieldErrors = [:]
        linkToRemove = nil
    }

    private func clearNavigation() {
        showsUnsavedChanges = false
        pendingNavigation = nil
        cancelNavigation = nil
    }
}
