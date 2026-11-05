import Foundation
import GRDB
import Observation

// The checklists of every job. Each job page types its checklist through its own editor, which
// saves as you type. The stored steps show wherever a checklist is not being typed, such as the
// progress on a watch page.
@Observable
final class ChecklistState {
    private let service: ChecklistService
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    private(set) var records: [ChecklistStepRecord] = []
    private(set) var isLoading = true
    private(set) var loadError: String?
    // The job whose checklist has the cursor, for the Checklist menu.
    private(set) var focusedJobID: UUID?
    @ObservationIgnored private var editors: [UUID: ChecklistEditor] = [:]

    init(
        service: ChecklistService,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.service = service
        self.pause = pause
    }

    // The editor of a job's checklist, made with its stored steps the first time it is asked
    // for.
    func editor(for jobID: UUID) -> ChecklistEditor {
        if let editor = editors[jobID] { return editor }
        let service = service
        let editor = ChecklistEditor(
            jobID: jobID, steps: stored(for: jobID),
            save: { steps in _ = try await service.save(steps, for: jobID) }, pause: pause)
        editor.editingChanged = { [weak self] id in self?.editingChanged(jobID, id) }
        editors[jobID] = editor
        return editor
    }

    // The step that has the cursor, and its checklist.
    var focusedStep: (editor: ChecklistEditor, id: UUID)? {
        guard let focusedJobID, let editor = editors[focusedJobID], let id = editor.editingID,
            editor.step(id) != nil
        else { return nil }
        return (editor, id)
    }

    func progress(for jobID: UUID) -> ChecklistProgress {
        if let editor = editors[jobID] { return editor.progress }
        return ChecklistProgress(stored(for: jobID))
    }

    var hasUnsavedChanges: Bool { editors.values.contains { $0.hasUnsavedChanges } }

    func observe() async {
        isLoading = true
        loadError = nil
        do {
            let values = try await service.coordinator.checklistValues()
            for try await stored in values {
                records = stored
                for editor in editors.values { editor.refresh(self.stored(for: editor.jobID)) }
                isLoading = false
            }
        } catch {
            if Task.isCancelled { return }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    func saveNow() {
        for editor in editors.values where editor.hasUnsavedChanges { editor.saveNow() }
    }

    func saveAll() async -> Bool {
        var succeeded = true
        for editor in editors.values where editor.hasUnsavedChanges {
            if await !editor.flush() { succeeded = false }
        }
        return succeeded
    }

    func discardUndo() {
        for editor in editors.values { editor.discardUndo() }
    }

    private func stored(for jobID: UUID) -> [ChecklistStep] {
        records.filter { $0.jobID == jobID }.sorted { lhs, rhs in
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            return lhs.id.uuidString < rhs.id.uuidString
        }.map(ChecklistStep.init(record:))
    }

    private func editingChanged(_ jobID: UUID, _ id: UUID?) {
        if id != nil {
            focusedJobID = jobID
        } else if focusedJobID == jobID {
            focusedJobID = nil
        }
    }
}
