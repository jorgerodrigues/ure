import Foundation
import GRDB
import Observation

// The jobs in the library and the page you write each one on. A job page has no draft: the
// title, the problem and what a waiting job waits for save on their own as you type. Changing
// the state saves at once, and Undo puts back the state the job had, with its dates. Every
// change goes through the library's edit queue, in the order you made it.
@Observable
final class JobState {
    static let stageActionName = "Change State"
    static let watchActionName = "Choose Watch"
    static let unsavedFields = "A field on this job did not save. Correct it or undo it first."

    let queue: EditQueue
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    private(set) var jobs: [JobRecord] = []
    private(set) var selectedID: UUID?
    private(set) var watchID: UUID?
    private(set) var isLoading = true
    private(set) var loadError: String?
    private(set) var facts: [UUID: JobFacts] = [:]
    // A job just started. Its page puts the cursor in its title.
    private(set) var titleToFocus: UUID?
    // A job just set to Waiting. Its page puts the cursor in what it waits for.
    private(set) var waitingToFocus: UUID?

    init(
        queue: EditQueue,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.queue = queue
        self.pause = pause
        queue.listen { [weak self] change, byUndo in self?.receive(change, byUndo: byUndo) }
    }

    // A job change, such as a state change or a new job, is still saving.
    var isSaving: Bool { queue.isBusy(.jobs) }
    var refusal: String? { queue.refusal(in: .jobs) }

    var selectedJob: JobRecord? { jobs.first { $0.id == selectedID } }

    func facts(for id: UUID) -> JobFacts? { facts[id] }

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
            let values = try await queue.coordinator.jobValues()
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
        queue.clearRefusal(in: .jobs)
    }

    func close() {
        selectedID = nil
        watchID = nil
        queue.clearRefusal(in: .jobs)
    }

    func startCommand(for watchID: UUID) { start(for: watchID) }

    // Opens the watch's open job, or starts one named "New Job" and puts the cursor in its
    // title, with the title selected, so typing replaces it. Nil when it opened a job that was
    // there already, or could not start one.
    @discardableResult
    func start(for watchID: UUID) -> EditTicket? {
        guard !isSaving, !isLoading, loadError == nil else { return nil }
        if let existing = openJob(for: watchID) {
            open(existing)
            return nil
        }
        return queue.submit(.job(.start(watchID)), in: .jobs) { [weak self] result in
            guard let self else { return }
            if case .failed(JobError.openJobExists(let existing)) = result {
                queue.clearRefusal(in: .jobs)
                adopt(existing)
                open(existing)
            }
            for case .job(let record) in result.changes {
                open(record)
                titleToFocus = record.id
            }
        }
    }

    // ⌘N and New Job in Jobs make a job without a watch, named "New Job", and put the cursor
    // in its title with the title selected. The watch picker comes next.
    func createCommand() { create() }

    @discardableResult
    func create() -> EditTicket? {
        guard !isSaving, !isLoading, loadError == nil else { return nil }
        return queue.submit(.job(.start(nil)), in: .jobs) { [weak self] result in
            guard let self else { return }
            for case .job(let record) in result.changes {
                open(record)
                titleToFocus = record.id
            }
        }
    }

    // Gives the selected job, which has no watch yet, the watch picked for it. ⌘Z puts back
    // "No watch yet", and Redo gives the job the watch again.
    @discardableResult
    func chooseWatch(
        _ watchID: UUID, undoManager: UndoManager? = nil,
        then: ((EditResult) -> Void)? = nil
    ) -> EditTicket? {
        guard !isSaving, let job = selectedJob, job.watchID == nil else { return nil }
        // A watch has one open job at a time, so an open job takes no watch that has one.
        if job.stage.isOpen, let open = openJob(for: watchID), open.id != job.id {
            queue.report(JobError.openJobExists(open).localizedDescription, in: .jobs)
            return nil
        }
        return queue.submit(
            .job(.watch(job.id, watchID)), in: .jobs, undo: Self.watchActionName,
            undoManager: undoManager
        ) { [weak self] result in
            self?.showWatch(of: result)
            then?(result)
        }
    }

    // Makes a watch with the name typed in the picker and gives it to the selected job. ⌘Z
    // puts back "No watch yet" and keeps the new watch. The job in the result has the new watch.
    @discardableResult
    func chooseNewWatch(
        named name: String, undoManager: UndoManager? = nil,
        then: ((EditResult) -> Void)? = nil
    ) -> EditTicket? {
        guard !isSaving, let job = selectedJob, job.watchID == nil else { return nil }
        return queue.submit(
            .job(.newWatch(job.id, name)), in: .jobs, undo: Self.watchActionName,
            undoManager: undoManager
        ) { [weak self] result in
            self?.showWatch(of: result)
            then?(result)
        }
    }

    // Picking a watch that already has an open job opens that job, because a watch has one
    // open job at a time. The job being set up goes when nothing is in it yet. It goes after
    // everything typed before, so a job with typing in it stays, and so does a job whose fields
    // show text that can't save, such as a cleared title.
    @discardableResult
    func openOpenJob(of watchID: UUID, discardingBlank blankID: UUID?) -> JobRecord? {
        guard !isSaving, let existing = openJob(for: watchID) else { return nil }
        if let blank = jobs.first(where: { $0.id == blankID }), blank.id != existing.id,
            blank.watchID == nil
        {
            queue.flushTyping()
            if facts[blank.id]?.hasUnsavedText != true {
                queue.submit(.job(.discardIfBlank(blank.id)), in: .jobs)
            }
        }
        open(existing)
        return existing
    }

    func titleFocused() { titleToFocus = nil }
    func waitingFocused() { waitingToFocus = nil }

    func setStageCommand(_ stage: JobStage, undoManager: UndoManager?) {
        setStage(stage, undoManager: undoManager)
    }

    // Moves the selected job to another state. Typing on the job saves first, so the change and
    // its Undo see it, and a field that does not save stops the change. Undo puts back the state
    // the job had, with its done date and what it waited for, and Redo the state it was given.
    // Choosing Waiting puts the cursor in what it waits for.
    @discardableResult
    func setStage(_ stage: JobStage, undoManager: UndoManager? = nil) -> EditTicket? {
        guard !isSaving, let job = selectedJob, job.stage != stage else { return nil }
        let id = job.id
        queue.flushTyping()
        if facts[id]?.hasRefusedText == true {
            queue.report(Self.unsavedFields, in: .jobs)
            return nil
        }
        // A job leaves Done only while its watch has no other open job.
        if !job.stage.isOpen, stage.isOpen, let watchID = job.watchID,
            let open = openJob(for: watchID), open.id != id
        {
            queue.report(JobError.openJobExists(open).localizedDescription, in: .jobs)
            return nil
        }
        return queue.submit(
            .job(.stage(id, stage)), in: .jobs, undo: Self.stageActionName,
            undoManager: undoManager,
            requires: EditCheck { [weak self] in
                self?.facts[id]?.hasUnsavedText == true ? Self.unsavedFields : nil
            }
        ) { [weak self] result in
            guard let self, result.isSaved, stage == .waiting, id == selectedID else { return }
            waitingToFocus = id
        }
    }

    private func showWatch(of result: EditResult) {
        for case .job(let job) in result.changes where job.id == selectedID {
            watchID = job.watchID
        }
    }

    private func receive(_ change: LibraryChange, byUndo: Bool) {
        switch change {
        case .job(let record):
            adopt(record, force: byUndo)
            if byUndo, record.id == selectedID { watchID = record.watchID }
        case .jobRemoved(let id):
            facts[id] = nil
            jobs.removeAll { $0.id == id }
        default:
            break
        }
    }

    private func adopt(_ record: JobRecord, force: Bool = false) {
        var records = jobs
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        apply(records, forcing: force ? record.id : nil)
    }

    // Undo and Redo of a job's fact show the stored value also in a field with the cursor.
    private func apply(_ records: [JobRecord], forcing forced: UUID? = nil) {
        jobs = records
        for record in records {
            if let existing = facts[record.id] {
                existing.refresh(record, force: record.id == forced)
            } else {
                facts[record.id] = JobFacts(job: record, queue: queue, pause: pause)
            }
        }
    }
}
