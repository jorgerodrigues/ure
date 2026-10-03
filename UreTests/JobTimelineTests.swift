import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct JobTimelineTests {
    private let clock = Date(timeIntervalSince1970: 1_778_307_200 + 21.0 / 4_194_304)

    @Test
    func committedEventsAndScopedNotesHaveStableOrderAcrossRestart() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = clock
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { clock }))
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let other = try await JobTaskFixture.job(coordinator)
        let jobs = JobService(coordinator: coordinator)
        _ = try await jobs.transition(job.id, using: JobTransitionDraft(stage: .inProgress))
        _ = try await jobs.setCondition(
            job.id,
            using: WatchConditionDraft(condition: .disassembled, note: "Opened for inspection"))
        let task = try await JobTaskService(coordinator: coordinator).save(
            JobTaskFixture.draft(.done), for: job.id, editing: nil)
        var part = PartFixture.draft()
        part.status = .arrived
        let savedPart = try await PartService(coordinator: coordinator).save(
            part, for: job.id, editing: nil)
        _ = try await jobs.transition(job.id, using: JobTransitionDraft(stage: .inProgress))
        _ = try await jobs.setCondition(
            job.id,
            using: WatchConditionDraft(condition: .disassembled, note: "Opened for inspection"))
        _ = try await JobTaskService(coordinator: coordinator).save(
            JobTaskDraft(task: task), for: job.id, editing: task.id)
        _ = try await PartService(coordinator: coordinator).save(
            PartDraft(part: savedPart), for: job.id, editing: savedPart.id)
        let notes = NoteService(coordinator: coordinator)
        var draft = NoteDraft(occurredAt: clock)
        draft.title = "Inspection"
        draft.body = "Å時計\n  Preserve spacing"
        let a = try await notes.save(draft, for: .job(job.id), editing: nil)
        let b = try await notes.save(draft, for: .job(job.id), editing: nil)
        draft.occurredAt = clock.addingTimeInterval(-100)
        let older = try await notes.save(draft, for: .job(job.id), editing: nil)
        draft.occurredAt = clock.addingTimeInterval(100)
        let newer = try await notes.save(draft, for: .job(job.id), editing: nil)
        _ = try await notes.save(draft, for: .watch(job.watchID), editing: nil)
        _ = try await notes.save(draft, for: .job(other.id), editing: nil)
        _ = try await jobs.transition(other.id, using: JobTransitionDraft(stage: .ready))
        let events = try await coordinator.read { db in
            try ActivityQueries.fetchAll(db).filter { $0.jobID == job.id }
        }
        let entries = try await fetch(job.id, coordinator)
        let tiedNoteIDs = [a.id, b.id].sorted { $0.uuidString < $1.uuidString }
        let expected: [JobTimelineEntry.ID] =
            [.note(newer.id)]
            + events.reversed().map { .event($0.id) }
            + tiedNoteIDs.map { .note($0) } + [.note(older.id)]
        #expect(entries.map(\.id) == expected)
        #expect(entries.filter { $0.ordering != nil }.count == 4)
        #expect(entries.first(where: { $0.source == .task(task.id) })?.summary == "Created as Done")
        #expect(
            entries.first(where: { $0.source == .part(savedPart.id) })?.summary
                == "Created as Arrived")
        #expect(entries.contains { $0.source == .watch(job.watchID) })
        #expect(entries.contains { $0.source == .job(job.id) })
        #expect(entries.first(where: { $0.id == .note(a.id) })?.body == a.body)
        #expect(entries.filter { $0.ordering != nil }.allSatisfy { $0.occurredAt == clock })
        try await coordinator.close()
        let reopened = fixture.coordinator()
        _ = try await reopened.open()
        #expect(try await fetch(job.id, reopened) == entries)
        try await reopened.close()
    }

    @Test
    func noteEditsReplaceOneEntryAndUseOccurredDate() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = clock
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { clock }))
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = NoteService(coordinator: coordinator)
        var draft = NoteDraft(occurredAt: clock.addingTimeInterval(-3600))
        draft.title = "Before cleaning"
        let note = try await service.save(draft, for: .job(job.id), editing: nil)
        var edit = NoteDraft(note: note)
        edit.title = "Corrected finding"
        edit.body = String(repeating: "時計 Å\n  Evidence.\n", count: 1500)
        let saved = try await service.save(edit, for: .job(job.id), editing: note.id)
        let entries = try await fetch(job.id, coordinator)
        #expect(entries.count == 1 && entries.first?.id == .note(note.id))
        #expect(entries.first?.occurredAt == note.occurredAt)
        #expect(entries.first?.title == saved.title && entries.first?.body == saved.body)
        #expect(try await coordinator.read(ActivityQueries.fetchAll).isEmpty)
        edit.occurredAt = clock.addingTimeInterval(3600)
        _ = try await service.save(edit, for: .job(job.id), editing: note.id)
        #expect(try await fetch(job.id, coordinator).first?.occurredAt == edit.occurredAt)
        try await coordinator.close()
    }

    @Test
    func removedSourcesKeepHistoricalTextAndProcurementValues() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = clock
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { clock }))
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let tasks = JobTaskService(coordinator: coordinator)
        var taskDraft = JobTaskFixture.draft(.done)
        taskDraft.title = String(repeating: "Long task Å時計 ", count: 400)
        let task = try await tasks.save(taskDraft, for: job.id, editing: nil)
        var rename = JobTaskDraft(task: task)
        rename.title = "Renamed task"
        _ = try await tasks.save(rename, for: job.id, editing: task.id)
        let parts = PartService(coordinator: coordinator)
        var draft = PartFixture.draft()
        draft.description = String(repeating: "Long part Å時計 ", count: 400)
        var link = PartLinkDraft()
        link.url = "https://example.org/0012"
        link.supplierName = "Saved supplier"
        link.price = "0012.3400"
        link.currency = "DKK"
        link.notes = "Evidence\n  Exact spacing"
        draft.links = [link]
        draft.selectedLinkID = link.id
        let needed = try await parts.save(draft, for: job.id, editing: nil)
        var order = PartDraft(part: needed)
        order.status = .ordered
        order.orderReference = "000042–Å"
        let ordered = try await parts.save(order, for: job.id, editing: needed.id)
        var correction = PartDraft(part: ordered)
        correction.status = .needed
        correction.statusReason = "Wrong lot"
        _ = try await parts.save(correction, for: job.id, editing: ordered.id)
        let before = try await fetch(job.id, coordinator)
        try await coordinator.mutate { db, _, _ in
            try db.execute(sql: "DELETE FROM jobTask WHERE id = ?", arguments: [task.id.uuidString])
            try db.execute(
                sql: "DELETE FROM partLink WHERE partID = ?", arguments: [ordered.id.uuidString])
            try db.execute(
                sql: "DELETE FROM partRequirement WHERE id = ?", arguments: [ordered.id.uuidString])
        }
        let entries = try await fetch(job.id, coordinator)
        #expect(entries.map(\.id) == before.map(\.id))
        #expect(entries.allSatisfy { $0.source == nil && $0.unavailableSource != nil })
        let history = try #require(
            entries.first { $0.title == ActivityKind.taskStatusChanged.rawValue })
        #expect(history.subject == taskDraft.title && history.next.first?.text == taskDraft.title)
        let partHistory = try #require(entries.first { $0.summary == "Ordered to Needed" })
        #expect(partHistory.subject == draft.description)
        #expect(partHistory.prior.contains { $0.label == "Price" && $0.text == "0012.3400" })
        #expect(partHistory.prior.contains { $0.label == "Ordered" && $0.date == clock })
        #expect(
            partHistory.prior.contains { $0.label == "Order reference" && $0.text == "000042–Å" })
        #expect(partHistory.next.contains { $0.label == "Reason" && $0.text == "Wrong lot" })
        try await coordinator.close()
    }

    @Test
    func failedWritesCannotAppearInHistory() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let before = try await fetch(job.id, coordinator)
        try await JobTaskFixture.failEvents(coordinator)
        await #expect(throws: DatabaseError.self) {
            try await JobTaskService(coordinator: coordinator).save(
                JobTaskFixture.draft(.done), for: job.id, editing: nil)
        }
        await #expect(throws: DatabaseError.self) {
            try await JobService(coordinator: coordinator).transition(
                job.id, using: JobTransitionDraft(stage: .inProgress))
        }
        await #expect(throws: DatabaseError.self) {
            try await JobService(coordinator: coordinator).setCondition(
                job.id, using: WatchConditionDraft(condition: .running, note: "Failed finding"))
        }
        var onHand = PartFixture.draft()
        onHand.status = .arrived
        await #expect(throws: DatabaseError.self) {
            try await PartService(coordinator: coordinator).save(onHand, for: job.id, editing: nil)
        }
        #expect(try await fetch(job.id, coordinator) == before)
        #expect(try await coordinator.read(JobTaskQueries.fetchAll).isEmpty)
        #expect(try await coordinator.read(PartQueries.fetchAll).isEmpty)
        #expect(try await coordinator.read { try JobQueries.fetch(job.id, in: $0) } == job)
        try await coordinator.close()
    }

    private func fetch(_ jobID: UUID, _ coordinator: LibraryCoordinator) async throws
        -> [JobTimelineEntry]
    {
        try await coordinator.read { try JobTimelineQueries.fetch(jobID, in: $0) }
    }
}
