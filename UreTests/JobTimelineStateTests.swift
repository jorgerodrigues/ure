import Foundation
import GRDB
import Testing

@testable import Ure

struct JobTimelineStateTests {
    @Test(.timeLimit(.minutes(1)))
    func observationRefreshesEditedNotesAndCommittedEventsOnly() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let timeline = JobTimelineState()
        let observation = Task { await timeline.observe(jobID: job.id, coordinator: coordinator) }
        defer { observation.cancel() }
        try await waitUntil { !timeline.isLoading }
        #expect(timeline.entries.isEmpty && timeline.loadError == nil)
        let service = NoteService(coordinator: coordinator)
        var draft = NoteDraft(occurredAt: Date(timeIntervalSince1970: 42))
        draft.title = "Initial finding"
        let note = try await service.save(draft, for: .job(job.id), editing: nil)
        try await waitUntil { timeline.entries.count == 1 }
        var edit = NoteDraft(note: note)
        edit.body = "Corrected finding"
        _ = try await service.save(edit, for: .job(job.id), editing: note.id)
        try await waitUntil { timeline.entries.first?.body == edit.body }
        #expect(
            timeline.entries.count == 1 && timeline.entries.first?.occurredAt == note.occurredAt)
        try await JobTaskFixture.failEvents(coordinator)
        await #expect(throws: DatabaseError.self) {
            try await JobTaskService(coordinator: coordinator).save(
                JobTaskFixture.draft(.done), for: job.id, editing: nil)
        }
        #expect(timeline.entries.count == 1)
        try await coordinator.mutate { db, _, _ in try db.execute(sql: "DROP TRIGGER failTaskEvent")
        }
        let task = try await JobTaskService(coordinator: coordinator).save(
            JobTaskFixture.draft(.done), for: job.id, editing: nil)
        try await waitUntil { timeline.entries.count == 2 }
        try await coordinator.mutate { db, _, _ in
            try db.execute(sql: "DELETE FROM jobTask WHERE id = ?", arguments: [task.id.uuidString])
        }
        try await waitUntil { timeline.entries.first?.unavailableSource != nil }
        #expect(timeline.entries.count == 2 && timeline.entries.first?.subject == task.title)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func loadingFailuresStayExplicitAndCanRetry() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        let timeline = JobTimelineState()
        let missing = UUID()
        await timeline.observe(jobID: missing, coordinator: coordinator)
        #expect(!timeline.isLoading && timeline.loadError != nil)
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        await timeline.observe(jobID: missing, coordinator: coordinator)
        #expect(timeline.loadError != nil)
        let observation = Task { await timeline.observe(jobID: job.id, coordinator: coordinator) }
        defer { observation.cancel() }
        try await waitUntil { !timeline.isLoading && timeline.loadError == nil }
        #expect(timeline.entries.isEmpty)
        observation.cancel()
        await observation.value
        let invalidID = try await coordinator.mutate { db, _, dependencies in
            let id = dependencies.makeID()
            let watch = try WatchQueries.fetch(job.watchID, in: db)
            let savedWatch = try #require(watch)
            try ActivityEvent(
                id: id, jobID: job.id, kind: .jobStageChanged, occurredAt: Date(), ordering: 1,
                priorValue: .condition(WatchConditionValue(watch: savedWatch)),
                nextValue: .condition(WatchConditionValue(watch: savedWatch))
            ).insert(db)
            return id
        }
        await timeline.observe(jobID: job.id, coordinator: coordinator)
        #expect(timeline.loadError == JobTimelineError.invalidEvent.localizedDescription)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: "DELETE FROM activityEvent WHERE id = ?", arguments: [invalidID.uuidString])
        }
        let retry = Task { await timeline.observe(jobID: job.id, coordinator: coordinator) }
        defer { retry.cancel() }
        try await waitUntil { !timeline.isLoading && timeline.loadError == nil }
        retry.cancel()
        await retry.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func sourceNavigationUsesExactRecordsAndProtectsDraftsOnClosedJobs() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let task = try await JobTaskService(coordinator: coordinator).save(
            JobTaskFixture.draft(.done), for: job.id, editing: nil)
        var partDraft = PartFixture.draft()
        partDraft.status = .arrived
        let part = try await PartService(coordinator: coordinator).save(
            partDraft, for: job.id, editing: nil)
        var noteDraft = NoteDraft()
        noteDraft.title = "Evidence"
        let note = try await NoteService(coordinator: coordinator).save(
            noteDraft, for: .job(job.id), editing: nil)
        let jobs = JobService(coordinator: coordinator)
        _ = try await jobs.setCondition(
            job.id, using: WatchConditionDraft(condition: .running, note: "Tested"))
        _ = try await jobs.transition(job.id, using: JobTransitionDraft(stage: .ready))
        let editing = makeEditing(coordinator)
        let timeline = JobTimelineState()
        let observations = [
            Task { await editing.watches.observe() }, Task { await editing.jobs.observe() },
            Task { await editing.tasks.observe() }, Task { await editing.parts.observe() },
            Task { await editing.notes.observe() },
            Task { await timeline.observe(jobID: job.id, coordinator: coordinator) },
        ]
        defer { observations.forEach { $0.cancel() } }
        try await waitUntil {
            !editing.watches.isLoading && !editing.jobs.isLoading && !editing.tasks.isLoading
                && !editing.parts.isLoading && !editing.notes.isLoading && !timeline.isLoading
        }
        editing.watches.select(job.watchID)
        editing.jobs.open(job)
        let taskEntry = try #require(timeline.entries.first { $0.source == .task(task.id) })
        let noteEntry = try #require(timeline.entries.first { $0.source == .note(note.id) })
        var opened = false
        timeline.openSource(noteEntry, jobID: job.id, editing: editing) { opened = true }
        #expect(opened && editing.notes.selectedNote == note)
        editing.notes.edit()
        editing.notes.draft?.body = "Keep this draft"
        opened = false
        timeline.openSource(taskEntry, jobID: job.id, editing: editing) { opened = true }
        #expect(editing.showsUnsavedChanges && !opened)
        editing.stay()
        #expect(editing.notes.draft?.body == "Keep this draft")
        timeline.openSource(taskEntry, jobID: job.id, editing: editing) { opened = true }
        await editing.saveAndContinue()
        #expect(opened && editing.tasks.selectedTask == task)
        #expect(editing.notes.owner == nil)
        let savedNote = try await coordinator.read { try NoteQueries.fetch(note.id, in: $0) }
        #expect(savedNote?.body == "Keep this draft")
        var closure = JobTransitionDraft(stage: .completed)
        closure.outcome = "Done"
        _ = try await jobs.transition(job.id, using: closure)
        try await waitUntil { editing.jobs.selectedJob?.stage == .completed }
        let partEntry = try #require(timeline.entries.first { $0.source == .part(part.id) })
        timeline.openSource(partEntry, jobID: job.id, editing: editing) { opened = true }
        #expect(editing.parts.selectedPart == part && editing.tasks.jobID == nil)
        #expect(!editing.parts.canWrite(job.id, jobs: editing.jobs))
        let jobEntry = try #require(timeline.entries.first { $0.source == .job(job.id) })
        timeline.openSource(jobEntry, jobID: job.id, editing: editing) { opened = true }
        #expect(editing.parts.jobID == nil && editing.jobs.selectedID == job.id)
        let watchEntry = try #require(timeline.entries.first { $0.source == .watch(job.watchID) })
        timeline.openSource(watchEntry, jobID: job.id, editing: editing) { opened = true }
        #expect(editing.jobs.selectedID == nil && editing.watches.selectedID == job.watchID)
        for observation in observations { observation.cancel(); await observation.value }
        try await coordinator.close()
    }

    private func makeEditing(_ coordinator: LibraryCoordinator) -> WorkshopEditing {
        WorkshopEditing(
            watches: WatchState(service: WatchService(coordinator: coordinator)),
            calibers: CaliberState(service: CaliberService(coordinator: coordinator)),
            jobs: JobState(service: JobService(coordinator: coordinator)),
            notes: NoteState(service: NoteService(coordinator: coordinator)),
            references: ReferenceState(service: ReferenceService(coordinator: coordinator)),
            photos: PhotoState(service: PhotoService(coordinator: coordinator)),
            documents: DocumentState(service: DocumentService(coordinator: coordinator)),
            tasks: JobTaskState(service: JobTaskService(coordinator: coordinator)),
            parts: PartState(service: PartService(coordinator: coordinator)))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TimelineObservationTimeout()
    }
}

nonisolated private struct TimelineObservationTimeout: Error {}
