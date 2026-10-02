import Foundation
import GRDB
import Observation

@Observable
final class JobState {
    private let service: JobService
    private var originalDraft: JobDraft?
    private var originalActionDraft: JobActionDraft?
    private var pendingNavigation: (() -> Void)?
    private var cancelNavigation: (() -> Void)?
    private(set) var jobs: [JobRecord] = []
    private(set) var selectedID: UUID?
    private(set) var watchID: UUID?
    private(set) var conflictingJobID: UUID?
    private(set) var isLoading = true
    private(set) var isSaving = false
    private(set) var loadError: String?
    private(set) var saveError: String?
    private(set) var fieldErrors: [JobField: String] = [:]
    var draft: JobDraft?
    var actionDraft: JobActionDraft?
    var showsUnsavedChanges = false

    init(service: JobService) {
        self.service = service
    }

    var selectedJob: JobRecord? { jobs.first { $0.id == selectedID } }
    var hasUnsavedChanges: Bool { draft != originalDraft || actionDraft != originalActionDraft }
    var canSave: Bool { (draft != nil || actionDraft != nil) && !isSaving }
    var isEditing: Bool { draft != nil || actionDraft != nil }
    var isNavigationPending: Bool { pendingNavigation != nil }

    func history(for watchID: UUID) -> [JobRecord] {
        jobs.filter { $0.watchID == watchID }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    func openJob(for watchID: UUID) -> JobRecord? {
        jobs.first { $0.watchID == watchID && $0.stage.isOpen }
    }

    func observe() async {
        isLoading = true
        loadError = nil
        do {
            let values = try await service.coordinator.jobValues()
            for try await records in values {
                jobs = records
                isLoading = false
            }
        } catch {
            if Task.isCancelled { return }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    func open(_ job: JobRecord) {
        requestNavigation {
            self.watchID = job.watchID
            self.selectedID = job.id
            self.clearErrors()
        }
    }

    func start(for watchID: UUID) {
        guard !isLoading, loadError == nil else { return }
        requestNavigation {
            self.watchID = watchID
            self.clearErrors()
            if let existing = self.openJob(for: watchID) {
                self.selectedID = existing.id
            } else {
                self.selectedID = nil
                self.draft = JobDraft()
                self.originalDraft = self.draft
            }
        }
    }

    func close() {
        requestNavigation {
            self.selectedID = nil
            self.watchID = nil
        }
    }

    func edit() {
        guard !isSaving, !isEditing, let selectedJob, selectedJob.stage.isOpen,
            selectedJob.intakeSnapshot.version == 1
        else { return }
        draft = JobDraft(job: selectedJob)
        originalDraft = draft
        clearErrors()
    }

    func beginAction(_ action: JobAction, watch: WatchRecord) {
        guard !isSaving, !isEditing, let job = selectedJob, job.watchID == watch.id else { return }
        if action == .reopen {
            guard !job.stage.isOpen else { return }
        } else {
            guard job.stage.isOpen else { return }
        }
        actionDraft = JobActionDraft(action: action, job: job, watch: watch)
        originalActionDraft = actionDraft
        clearErrors()
    }

    func openConflictingJob() {
        guard let id = conflictingJobID, let job = jobs.first(where: { $0.id == id }) else {
            return
        }
        open(job)
    }

    func cancel() {
        guard !isSaving else { return }
        draft = nil
        originalDraft = nil
        actionDraft = nil
        originalActionDraft = nil
        clearErrors()
    }

    @discardableResult
    func save() async -> Bool {
        guard !isSaving, let watchID, isEditing else { return false }
        isSaving = true
        clearErrors()
        defer { isSaving = false }
        do {
            let saved: JobRecord?
            if let actionDraft, let selectedID {
                switch actionDraft.action {
                case .transition:
                    saved = try await service.transition(selectedID, using: actionDraft.transition)
                case .reopen:
                    saved = try await service.reopen(selectedID, using: actionDraft.transition)
                case .condition:
                    _ = try await service.setCondition(selectedID, using: actionDraft.condition)
                    saved = nil
                }
            } else if let draft {
                saved = try await service.save(draft, for: watchID, editing: selectedID)
            } else {
                return false
            }
            if let saved {
                if let index = jobs.firstIndex(where: { $0.id == saved.id }) {
                    jobs[index] = saved
                } else {
                    jobs.append(saved)
                }
                selectedID = saved.id
            }
            self.draft = nil
            originalDraft = nil
            self.actionDraft = nil
            originalActionDraft = nil
            return true
        } catch {
            saveError = error.localizedDescription
            if let conflict = error as? JobError, case .openJobExists(let existing) = conflict {
                conflictingJobID = existing.id
                if let index = jobs.firstIndex(where: { $0.id == existing.id }) {
                    jobs[index] = existing
                } else {
                    jobs.append(existing)
                }
            }
            if let validation = error as? JobValidationError {
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
        conflictingJobID = nil
        fieldErrors = [:]
    }

    private func clearNavigation() {
        showsUnsavedChanges = false
        pendingNavigation = nil
        cancelNavigation = nil
    }
}
