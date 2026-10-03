import Foundation
import GRDB
import Observation

@Observable
final class JobTaskState {
    private let service: JobTaskService
    private var originalDraft: JobTaskDraft?
    private var pendingNavigation: (() -> Void)?
    private var cancelNavigation: (() -> Void)?
    private(set) var tasks: [JobTaskRecord] = []
    private(set) var jobID: UUID?
    private(set) var selectedID: UUID?
    private(set) var isLoading = true
    private(set) var isSaving = false
    private(set) var loadError: String?
    private(set) var saveError: String?
    private(set) var reorderError: String?
    private(set) var fieldErrors: [JobTaskField: String] = [:]
    var draft: JobTaskDraft?
    var showsUnsavedChanges = false

    init(service: JobTaskService) { self.service = service }

    var selectedTask: JobTaskRecord? {
        tasks.first { $0.id == selectedID && $0.jobID == jobID }
    }
    var hasUnsavedChanges: Bool { draft != originalDraft }
    var isNavigationPending: Bool { pendingNavigation != nil }

    func records(for jobID: UUID) -> [JobTaskRecord] {
        tasks.filter { $0.jobID == jobID }.sorted { lhs, rhs in
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    func progress(for jobID: UUID) -> JobTaskProgress {
        JobTaskProgress(tasks: records(for: jobID))
    }

    func canReorder(_ jobID: UUID, jobs: JobState) -> Bool {
        !isSaving && draft == nil && !isNavigationPending && canWrite(jobID, jobs: jobs)
    }

    func canMove(_ id: UUID, for jobID: UUID, to destination: JobTaskMove, jobs: JobState) -> Bool {
        guard canReorder(jobID, jobs: jobs) else { return false }
        let records = records(for: jobID)
        guard let source = records.firstIndex(where: { $0.id == id }) else { return false }
        switch destination {
        case .up: return source > 0
        case .down, .end: return source < records.count - 1
        case .before(let targetID):
            guard let target = records.firstIndex(where: { $0.id == targetID }) else {
                return false
            }
            return source != target && source + 1 != target
        }
    }

    @discardableResult
    func move(_ id: UUID, for jobID: UUID, to destination: JobTaskMove, jobs: JobState) async
        -> Bool
    {
        guard canMove(id, for: jobID, to: destination, jobs: jobs) else { return false }
        isSaving = true
        reorderError = nil
        defer { isSaving = false }
        do {
            let saved = try await service.move(id, for: jobID, to: destination)
            tasks.removeAll { $0.jobID == jobID }
            tasks.append(contentsOf: saved)
            return true
        } catch {
            reorderError =
                "Could not move the task. The previous order has been kept. \(error.localizedDescription)"
            return false
        }
    }

    func moveCommand(_ id: UUID, for jobID: UUID, to destination: JobTaskMove, jobs: JobState) {
        Task { await move(id, for: jobID, to: destination, jobs: jobs) }
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
            let values = try await service.coordinator.taskValues()
            for try await records in values {
                tasks = records
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
            self.draft = JobTaskDraft()
            self.originalDraft = self.draft
            self.clearErrors()
        }
    }

    func open(_ task: JobTaskRecord, for jobID: UUID) {
        guard task.jobID == jobID else { return }
        requestNavigation {
            self.jobID = jobID
            self.selectedID = task.id
            self.clearErrors()
        }
    }

    func edit(jobs: JobState) {
        guard !isSaving, draft == nil, let selectedTask,
            canWrite(selectedTask.jobID, jobs: jobs)
        else { return }
        draft = JobTaskDraft(task: selectedTask)
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
            if let index = tasks.firstIndex(where: { $0.id == saved.id }) {
                tasks[index] = saved
            } else {
                tasks.append(saved)
            }
            selectedID = saved.id
            self.draft = nil
            originalDraft = nil
            return true
        } catch {
            saveError = error.localizedDescription
            if let validation = error as? JobTaskValidationError { fieldErrors = validation.fields }
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
        reorderError = nil
        fieldErrors = [:]
    }

    private func clearNavigation() {
        showsUnsavedChanges = false
        pendingNavigation = nil
        cancelNavigation = nil
    }
}
