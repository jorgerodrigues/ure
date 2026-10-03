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
    private(set) var parts: [PartRecord] = []
    private(set) var links: [TaskPart] = []
    private(set) var jobID: UUID?
    private(set) var selectedID: UUID?
    private(set) var isLoading = true
    private(set) var isSaving = false
    private(set) var loadError: String?
    private(set) var saveError: String?
    private(set) var reorderError: String?
    private(set) var fieldErrors: [JobTaskField: String] = [:]
    var draft: JobTaskDraft?
    var showsRemovalConfirmation = false
    private var removalID: UUID?
    private var removalPartIDs: Set<UUID> = []
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

    func availableParts(for jobID: UUID) -> [PartRecord] {
        parts.filter { $0.jobID == jobID }
    }

    func linkedParts(for taskID: UUID) -> [PartRecord] {
        let ids = Set(links.filter { $0.taskID == taskID }.map(\.partID))
        return parts.filter { ids.contains($0.id) }
    }

    func availability(for taskID: UUID) -> TaskPartAvailability? {
        guard !isLoading, loadError == nil else { return nil }
        return TaskPartAvailability.label(for: linkedParts(for: taskID))
    }

    func selectPart(_ id: UUID, selected: Bool) {
        guard !isSaving, let jobID, draft != nil,
            parts.contains(where: { $0.id == id && $0.jobID == jobID })
        else { return }
        if selected {
            draft?.partIDs.insert(id)
        } else {
            draft?.partIDs.remove(id)
        }
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
            for try await snapshot in values {
                tasks = snapshot.tasks
                parts = snapshot.parts
                links = snapshot.links
                if let selectedID, draft == nil, !tasks.contains(where: { $0.id == selectedID }) {
                    self.selectedID = nil
                    self.jobID = nil
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
        draft = JobTaskDraft(
            task: selectedTask, partIDs: Set(linkedParts(for: selectedTask.id).map(\.id)))
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
        showsRemovalConfirmation = false
        removalID = nil
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
            links.removeAll { $0.taskID == saved.id }
            links.append(contentsOf: draft.partIDs.map { TaskPart(taskID: saved.id, partID: $0) })
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

    func requestRemoval() {
        guard !isSaving, draft == nil, !isLoading, loadError == nil,
            let record = selectedTask
        else { return }
        removalID = record.id
        removalPartIDs = Set(linkedParts(for: record.id).map(\.id))
        showsRemovalConfirmation = true
    }

    func removeCommand() { Task { await remove() } }

    @discardableResult
    func remove() async -> Bool {
        guard !isSaving, draft == nil, let id = removalID,
            selectedID == id, let jobID
        else { return false }
        isSaving = true
        showsRemovalConfirmation = false
        clearErrors()
        defer { isSaving = false; removalID = nil }
        do {
            let saved = try await ChildRemovalService(coordinator: service.coordinator).removeTask(
                id, for: jobID, confirmedPartIDs: removalPartIDs)
            tasks.removeAll { $0.jobID == jobID }
            tasks.append(contentsOf: saved)
            links.removeAll { $0.taskID == id }
            selectedID = nil
            self.jobID = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    var removalMessage: String {
        guard let id = removalID else { return "Remove this task?" }
        let names = linkedParts(for: id).sorted { $0.id.uuidString < $1.id.uuidString }.map {
            "• \($0.description) (\($0.status.rawValue))"
        }
        if names.isEmpty { return "The task will be removed. Its activity summaries will be kept." }
        return
            "The task and these links will be removed. The parts and activity summaries will be kept.\n"
            + names.joined(separator: "\n")
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
