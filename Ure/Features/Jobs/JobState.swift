import Foundation
import GRDB
import Observation

// The jobs in the library and the page you write each one on. A job page has no draft: the
// title, the problem and what a waiting job waits for save on their own as you type. Changing
// the state saves at once, and Undo puts back the state the job had, with its dates.
@Observable
final class JobState {
    static let stageActionName = "Change State"

    private let service: JobService
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    @ObservationIgnored private let stages = ChangeUndo<JobStageValue>()
    private(set) var jobs: [JobRecord] = []
    private(set) var selectedID: UUID?
    private(set) var watchID: UUID?
    private(set) var isLoading = true
    private(set) var isSaving = false
    private(set) var loadError: String?
    private(set) var saveError: String?
    private(set) var facts: [UUID: JobFacts] = [:]
    // A job just started. Its page puts the cursor in its title.
    private(set) var titleToFocus: UUID?
    // A job just set to Waiting. Its page puts the cursor in what it waits for.
    private(set) var waitingToFocus: UUID?

    init(
        service: JobService,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.service = service
        self.pause = pause
    }

    var selectedJob: JobRecord? { jobs.first { $0.id == selectedID } }

    func facts(for id: UUID) -> JobFacts? { facts[id] }

    var hasUnsavedFacts: Bool { facts.values.contains { $0.hasUnsavedChanges } }

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
                apply(records)
                isLoading = false
            }
        } catch {
            if Task.isCancelled { return }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    func open(_ job: JobRecord) {
        watchID = job.watchID
        selectedID = job.id
        saveError = nil
    }

    func close() {
        selectedID = nil
        watchID = nil
        saveError = nil
    }

    func startCommand(for watchID: UUID) { Task { await start(for: watchID) } }

    // Opens the watch's open job, or starts one named "New Job" and puts the cursor in its
    // title, with the title selected, so typing replaces it.
    @discardableResult
    func start(for watchID: UUID) async -> Bool {
        guard !isSaving, !isLoading, loadError == nil else { return false }
        if let existing = openJob(for: watchID) {
            open(existing)
            return true
        }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let record = try await service.start(for: watchID)
            adopt(record)
            open(record)
            titleToFocus = record.id
            return true
        } catch JobError.openJobExists(let existing) {
            adopt(existing)
            open(existing)
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    func titleFocused() { titleToFocus = nil }
    func waitingFocused() { waitingToFocus = nil }

    func setStageCommand(_ stage: JobStage, undoManager: UndoManager?) {
        Task { await setStage(stage, undoManager: undoManager) }
    }

    // Moves the selected job to another state. Undo puts back the state it had, with its done
    // date and what it waited for, and Redo the state it was given. Choosing Waiting puts the
    // cursor in what it waits for.
    @discardableResult
    func setStage(_ stage: JobStage, undoManager: UndoManager? = nil) async -> Bool {
        guard !isSaving, let job = selectedJob, job.stage != stage else { return false }
        let id = job.id
        return await stages.perform(JobStageValue(stage: stage)) { [weak self] _ in
            await self?.changeStage(id, to: stage, undoManager: undoManager) ?? false
        }
    }

    // Waits for a state change that Undo or Redo started.
    func waitForStageChanges() async { await stages.wait() }

    func saveFactsNow() {
        for editor in unsavedEditors { editor.saveNow() }
    }

    func saveAllFacts() async -> Bool {
        var succeeded = true
        for editor in unsavedEditors {
            if await !editor.flush() { succeeded = false }
        }
        return succeeded
    }

    func discardUndo() {
        for facts in facts.values {
            for editor in facts.editors { editor.discardUndo() }
        }
        stages.discardUndo()
    }

    private var unsavedEditors: [AutosaveField] {
        facts.values.flatMap(\.editors).filter(\.hasUnsavedChanges)
    }

    private func changeStage(_ id: UUID, to stage: JobStage, undoManager: UndoManager?) async
        -> Bool
    {
        guard await prepareStageChange(id) else { return false }
        defer { isSaving = false }
        do {
            let change = try await service.setStage(id, to: stage)
            adopt(change.job)
            let next = JobStageValue(job: change.job)
            guard next != change.prior else { return true }
            let restore: ChangeUndo<JobStageValue>.Write = { [weak self] value in
                await self?.restoreStage(id, to: value) ?? false
            }
            stages.registerUndo(
                setting: change.prior, redoing: next, actionName: Self.stageActionName,
                undoManager: undoManager, write: restore)
            if stage == .waiting, id == selectedID { waitingToFocus = id }
            return true
        } catch {
            fail(error)
            return false
        }
    }

    private func restoreStage(_ id: UUID, to value: JobStageValue) async -> Bool {
        guard await prepareStageChange(id) else { return false }
        defer { isSaving = false }
        do {
            adopt(try await service.restoreStage(id, to: value))
            return true
        } catch {
            fail(error)
            return false
        }
    }

    // Typing still saving on the job finishes first, so the change sees it. A fact that does
    // not save stops the change.
    private func prepareStageChange(_ id: UUID) async -> Bool {
        isSaving = true
        saveError = nil
        for editor in facts[id]?.editors ?? [] where editor.hasUnsavedChanges {
            guard await editor.flush() else {
                saveError = "A field on this job did not save. Correct it or undo it first."
                isSaving = false
                return false
            }
        }
        return true
    }

    private func fail(_ error: any Error) {
        saveError = error.localizedDescription
        if let conflict = error as? JobError, case .openJobExists(let existing) = conflict {
            adopt(existing)
        }
    }

    private func adopt(_ record: JobRecord) {
        var records = jobs
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        apply(records)
    }

    private func apply(_ records: [JobRecord]) {
        jobs = records
        for record in records {
            if let existing = facts[record.id] {
                existing.refresh(record)
            } else {
                facts[record.id] = JobFacts(job: record, service: service, pause: pause)
            }
        }
    }
}
