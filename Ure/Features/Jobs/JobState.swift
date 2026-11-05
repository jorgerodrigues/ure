import Foundation
import GRDB
import Observation

// The jobs in the library and the page you write each one on. A job page has no draft: the
// title, the problem and what a waiting job waits for save on their own as you type. Changing
// the state saves at once, and Undo puts back the state the job had, with its dates.
@Observable
final class JobState {
    static let stageActionName = "Change State"
    static let watchActionName = "Choose Watch"

    private let service: JobService
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    @ObservationIgnored private let stages = ChangeUndo<JobStageValue>()
    @ObservationIgnored private let watchChoices = ChangeUndo<UUID?>()
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

    // ⌘N and New Job in Jobs make a job without a watch, named "New Job", and put the cursor
    // in its title with the title selected. The watch picker comes next.
    func createCommand() { Task { await create() } }

    @discardableResult
    func create() async -> Bool {
        guard !isSaving, !isLoading, loadError == nil else { return false }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let record = try await service.start(for: nil)
            adopt(record)
            open(record)
            titleToFocus = record.id
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    // Gives the selected job, which has no watch yet, the watch picked for it. ⌘Z puts back
    // "No watch yet", and Redo gives the job the watch again.
    @discardableResult
    func chooseWatch(_ watchID: UUID, undoManager: UndoManager? = nil) async -> Bool {
        guard !isSaving, let job = selectedJob, job.watchID == nil else { return false }
        let id = job.id
        return await watchChoices.perform(watchID) { [weak self] _ in
            await self?.changeWatch(id, undoManager: undoManager) {
                try await $0.setWatch(id, to: watchID)
            } ?? false
        }
    }

    // Makes a watch with the name typed in the picker and gives it to the selected job. ⌘Z
    // puts back "No watch yet" and keeps the new watch. Returns the new watch.
    @discardableResult
    func chooseNewWatch(named name: String, undoManager: UndoManager? = nil) async -> UUID? {
        guard !isSaving, let job = selectedJob, job.watchID == nil else { return nil }
        let id = job.id
        var made: UUID?
        _ = await watchChoices.perform(nil) { [weak self] _ in
            await self?.changeWatch(id, undoManager: undoManager) { service in
                let job = try await service.setNewWatch(id, named: name)
                made = job.watchID
                return job
            } ?? false
        }
        return made
    }

    // Picking a watch that already has an open job opens that job, because a watch has one
    // open job at a time. The job being set up goes when nothing is in it yet.
    @discardableResult
    func openOpenJob(of watchID: UUID) async -> JobRecord? {
        guard !isSaving, let existing = openJob(for: watchID) else { return nil }
        if let blank = selectedJob, blank.id != existing.id, blank.watchID == nil {
            isSaving = true
            defer { isSaving = false }
            if (try? await service.discardIfBlank(blank.id)) == true {
                facts[blank.id] = nil
                jobs.removeAll { $0.id == blank.id }
            }
        }
        open(existing)
        return existing
    }

    // Waits for a watch choice that Undo or Redo started.
    func waitForWatchChanges() async { await watchChoices.wait() }

    func titleFocused() { titleToFocus = nil }
    func waitingFocused() { waitingToFocus = nil }

    func setStageCommand(_ stage: JobStage, undoManager: UndoManager?) {
        Task { await setStage(stage, undoManager: undoManager) }
    }

    // Moves the selected job to another state. Typing still saving on the job saves first, so
    // the change and its Undo see it. Undo puts back the state the job had, with its done date
    // and what it waited for, and Redo the state it was given. Choosing Waiting puts the cursor
    // in what it waits for.
    @discardableResult
    func setStage(_ stage: JobStage, undoManager: UndoManager? = nil) async -> Bool {
        guard !isSaving, let job = selectedJob, job.stage != stage else { return false }
        let id = job.id
        guard await saveTyping(on: id) else { return false }
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
        watchChoices.discardUndo()
    }

    private var unsavedEditors: [AutosaveField] {
        facts.values.flatMap(\.editors).filter(\.hasUnsavedChanges)
    }

    // A state change never waits for a field, because a waiting text waits for state changes.
    private func changeStage(_ id: UUID, to stage: JobStage, undoManager: UndoManager?) async
        -> Bool
    {
        isSaving = true
        saveError = nil
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

    private func changeWatch(
        _ id: UUID, undoManager: UndoManager?,
        write: (JobService) async throws -> JobRecord
    ) async -> Bool {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let prior = jobs.first { $0.id == id }?.watchID
            let job = try await write(service)
            adopt(job)
            if selectedID == id { watchID = job.watchID }
            guard job.watchID != prior else { return true }
            let restore: ChangeUndo<UUID?>.Write = { [weak self] value in
                await self?.restoreWatch(id, to: value) ?? false
            }
            watchChoices.registerUndo(
                setting: prior, redoing: job.watchID, actionName: Self.watchActionName,
                undoManager: undoManager, write: restore)
            return true
        } catch {
            fail(error)
            return false
        }
    }

    private func restoreWatch(_ id: UUID, to watchID: UUID?) async -> Bool {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let job = try await service.setWatch(id, to: watchID)
            adopt(job)
            if selectedID == id { self.watchID = job.watchID }
            return true
        } catch {
            fail(error)
            return false
        }
    }

    // Undo and Redo reach a state change only after the typing made since, so nothing typed on
    // the job is waiting to save.
    private func restoreStage(_ id: UUID, to value: JobStageValue) async -> Bool {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            adopt(try await service.restoreStage(id, to: value))
            return true
        } catch {
            fail(error)
            return false
        }
    }

    // A field that does not save stops the state change.
    private func saveTyping(on id: UUID) async -> Bool {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        for editor in facts[id]?.editors ?? [] where editor.hasUnsavedChanges {
            guard await editor.flush() else {
                saveError = "A field on this job did not save. Correct it or undo it first."
                return false
            }
        }
        return true
    }

    // Waits for state changes still saving, then says whether the job still waits.
    private func stillWaits(_ id: UUID) async -> Bool {
        await stages.wait()
        return jobs.first { $0.id == id }?.stage == .waiting
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
                let id = record.id
                facts[id] = JobFacts(
                    job: record, service: service,
                    stillWaits: { [weak self] in await self?.stillWaits(id) ?? false },
                    pause: pause)
            }
        }
    }
}
