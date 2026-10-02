import Foundation
import GRDB
import Observation

@Observable
final class NoteState {
    private let service: NoteService
    private var originalDraft: NoteDraft?
    private var pendingNavigation: (() -> Void)?
    private var cancelNavigation: (() -> Void)?
    private(set) var notes: [NoteRecord] = []
    private(set) var owner: NoteOwner?
    private(set) var selectedID: UUID?
    private(set) var isLoading = true
    private(set) var isSaving = false
    private(set) var loadError: String?
    private(set) var saveError: String?
    private(set) var fieldErrors: [NoteField: String] = [:]
    var draft: NoteDraft?
    var showsUnsavedChanges = false

    init(service: NoteService) { self.service = service }

    var selectedNote: NoteRecord? {
        guard let owner else { return nil }
        return notes.first { $0.id == selectedID && $0.belongs(to: owner) }
    }
    var hasUnsavedChanges: Bool { draft != originalDraft }
    var canSave: Bool { draft != nil && !isSaving }
    var isNavigationPending: Bool { pendingNavigation != nil }

    func records(for owner: NoteOwner) -> [NoteRecord] {
        notes.filter { $0.belongs(to: owner) }.sorted { lhs, rhs in
            if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    func isPresenting(for owner: NoteOwner) -> Bool {
        self.owner == owner && (selectedID != nil || draft != nil)
    }

    func canWrite(_ owner: NoteOwner, jobs: JobState) -> Bool {
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
            let values = try await service.coordinator.noteValues()
            for try await records in values {
                notes = records
                isLoading = false
            }
        } catch {
            if Task.isCancelled { return }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    func create(for owner: NoteOwner) {
        guard !isLoading, loadError == nil else { return }
        requestNavigation {
            self.owner = owner
            self.selectedID = nil
            self.draft = NoteDraft()
            self.originalDraft = self.draft
            self.clearErrors()
        }
    }

    func open(_ note: NoteRecord, for owner: NoteOwner) {
        guard note.belongs(to: owner) else { return }
        requestNavigation {
            self.owner = owner
            self.selectedID = note.id
            self.clearErrors()
        }
    }

    func edit() {
        guard !isSaving, draft == nil, let selectedNote else { return }
        draft = NoteDraft(note: selectedNote)
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
            if let index = notes.firstIndex(where: { $0.id == saved.id }) {
                notes[index] = saved
            } else {
                notes.append(saved)
            }
            selectedID = saved.id
            self.draft = nil
            originalDraft = nil
            return true
        } catch {
            saveError = error.localizedDescription
            if let validation = error as? NoteValidationError { fieldErrors = validation.fields }
            return false
        }
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
        fieldErrors = [:]
    }

    private func clearNavigation() {
        showsUnsavedChanges = false
        pendingNavigation = nil
        cancelNavigation = nil
    }
}
