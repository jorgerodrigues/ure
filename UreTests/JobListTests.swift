import Foundation
import GRDB
import Testing

@testable import Ure

struct JobListTests {
    // The list's days follow this calendar, so the tests do not depend on the Mac's time zone.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    // 5 November 2026 at 15:00.
    static func now() throws -> Date {
        try #require(
            calendar.date(
                from: DateComponents(year: 2026, month: 11, day: 5, hour: 15)))
    }

    static func daysAgo(_ days: Int, hour: Int = 12) throws -> Date {
        let today = calendar.startOfDay(for: try now())
        let day = try #require(calendar.date(byAdding: .day, value: -days, to: today))
        return try #require(calendar.date(byAdding: .hour, value: hour, to: day))
    }

    @Test
    func theRecentCutoffIsTheStartOfTheDayThirtyDaysAgo() throws {
        let cutoff = JobListState.recentCutoff(now: try Self.now(), calendar: Self.calendar)
        #expect(cutoff == (try Self.daysAgo(30, hour: 0)))
        let midnight = Self.calendar.startOfDay(for: try Self.now())
        #expect(
            JobListState.recentCutoff(now: midnight, calendar: Self.calendar) == cutoff)
    }

    @Test
    func doneRecentlyHoldsJobsDoneOnAnyOfTheLastThirtyDays() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let now = try Self.now()
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { now }))
        _ = try await coordinator.open()
        let cutoff = JobListState.recentCutoff(now: now, calendar: Self.calendar)
        let doneAt = [
            "29 days ago": try Self.daysAgo(29),
            "30 days ago": try Self.daysAgo(30),
            "the first moment of 30 days ago": cutoff,
            "the last moment of 31 days ago": cutoff.addingTimeInterval(-1),
            "31 days ago": try Self.daysAgo(31),
        ]
        var ids: [String: UUID] = [:]
        for (name, date) in doneAt {
            let job = try await JobListFixture.done(coordinator, at: date)
            ids[name] = job.id
        }
        let rows = try await coordinator.read { try JobListQueries.fetch($0, doneSince: cutoff) }
        let listed = Set(rows.map(\.id))
        for name in ["29 days ago", "30 days ago", "the first moment of 30 days ago"] {
            #expect(ids[name].map(listed.contains) == true, "\(name)")
        }
        for name in ["the last moment of 31 days ago", "31 days ago"] {
            #expect(ids[name].map(listed.contains) == false, "\(name)")
        }

        // When the day changes, a job leaves the list the day it turns 31 days old, also
        // without a change to the library.
        let clock = JobListClock(now: now)
        let state = JobListState(
            coordinator: coordinator, now: { clock.now }, calendar: Self.calendar)
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await JobListFixture.waitUntil { !state.isLoading }
        #expect(state.rows(in: .doneRecently).count == 3)
        #expect(state.listedRows.count == 3)
        clock.now = now.addingTimeInterval(86_400)
        #expect(state.rows(in: .doneRecently).count == 3)
        state.refreshDay()
        #expect(state.cutoff == (try Self.daysAgo(29, hour: 0)))
        #expect(state.listedRows.count == 1)
        #expect(
            Set(state.rows(in: .doneRecently).map(\.id))
                == Set(["29 days ago"].compactMap { ids[$0] }))
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test
    func everyOpenJobShowsOnceInItsGroupWithItsProgress() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let now = try Self.now()
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { now }))
        _ = try await coordinator.open()
        let jobs = JobService(coordinator: coordinator)
        let service = try await JobTaskFixture.job(coordinator)
        // Two of three steps are ticked. The heading does not count.
        _ = try await ChecklistService(coordinator: coordinator).save(
            [
                ChecklistStep(id: UUID(), text: "Cleaning", isHeading: true),
                ChecklistStep(id: UUID(), text: "Clean all parts", isTicked: true),
                ChecklistStep(id: UUID(), text: "Inspect pivots", isTicked: true),
                ChecklistStep(id: UUID(), text: "Oil the movement"),
            ], for: service.id)
        let parts = PartService(coordinator: coordinator)
        _ = try await parts.save(PartFixture.draft(), for: service.id, editing: nil)
        let ordered = try await parts.save(PartFixture.draft(), for: service.id, editing: nil)
        var order = PartDraft(part: ordered)
        order.status = .ordered
        _ = try await parts.save(order, for: service.id, editing: ordered.id)
        let waiting = try await JobTaskFixture.job(coordinator)
        _ = try await jobs.setStage(waiting.id, to: .waiting)
        _ = try await jobs.update(waiting.id, .waitingFor("a mainspring"))
        let unwatched = try await jobs.start(for: nil, title: "New crystal")
        let recent = try await JobListFixture.done(coordinator, at: try Self.daysAgo(3))
        _ = try await JobListFixture.done(coordinator, at: try Self.daysAgo(40))
        let archived = try await JobTaskFixture.job(coordinator)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: "UPDATE job SET archivedAt = 1 WHERE id = ?",
                arguments: [archived.id.uuidString])
        }

        let state = JobListState(coordinator: coordinator, now: { now }, calendar: Self.calendar)
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await JobListFixture.waitUntil { !state.isLoading }
        let grouped = JobListGroup.allCases.flatMap { state.rows(in: $0).map(\.id) }
        #expect(grouped.count == Set(grouped).count)
        #expect(Set(state.rows(in: .inProgress).map(\.id)) == [service.id, unwatched.id])
        #expect(state.rows(in: .waiting).map(\.id) == [waiting.id])
        #expect(state.rows(in: .doneRecently).map(\.id) == [recent.id])
        #expect(state.listedRows.count == 4)
        #expect(state.subtitle == "3 open · 1 waiting")

        let serviceRow = try #require(state.listedRows.first { $0.id == service.id })
        #expect(JobListWording.title(of: serviceRow) == "Omega 0012–Å")
        #expect(
            JobListWording.detail(of: serviceRow, now: now)
                == "Service movement · 2 of 3 · 1 to buy")
        let waitingRow = try #require(state.listedRows.first { $0.id == waiting.id })
        #expect(JobListWording.detail(of: waitingRow, now: now) == "Waiting for a mainspring")
        let unwatchedRow = try #require(state.listedRows.first { $0.id == unwatched.id })
        #expect(unwatchedRow.watch == nil)
        #expect(JobListWording.title(of: unwatchedRow) == "New crystal")
        #expect(JobListWording.detail(of: unwatchedRow, now: now) == "No watch yet")
        let recentRow = try #require(state.listedRows.first { $0.id == recent.id })
        let doneAt = try #require(recentRow.job.doneAt)
        #expect(
            JobListWording.detail(of: recentRow, now: now)
                == "Service movement · Done \(ArchivedDate.short(doneAt, now: now))")
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test
    func openJobsListTheNewestChangeFirstAndDoneJobsTheLatestDoneFirst() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let now = try Self.now()
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { now }))
        _ = try await coordinator.open()
        let older = try await JobTaskFixture.job(coordinator)
        let newer = try await JobTaskFixture.job(coordinator)
        let step = try #require(
            try await ChecklistService(coordinator: coordinator).save(
                [ChecklistStep(id: UUID(), text: "Clean all parts")], for: older.id
            ).first)
        let first = try await JobListFixture.done(coordinator, at: try Self.daysAgo(10))
        let second = try await JobListFixture.done(coordinator, at: try Self.daysAgo(2))
        try await coordinator.mutate { db, _, _ in
            try db.execute(sql: "UPDATE job SET updatedAt = 100")
            try db.execute(
                sql: "UPDATE checklistStep SET updatedAt = 300 WHERE id = ?",
                arguments: [step.id.uuidString])
            try db.execute(
                sql: "UPDATE job SET updatedAt = 200 WHERE id = ?",
                arguments: [newer.id.uuidString])
        }
        let state = JobListState(coordinator: coordinator, now: { now }, calendar: Self.calendar)
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await JobListFixture.waitUntil { !state.isLoading && state.rows.count == 4 }
        #expect(state.rows(in: .inProgress).map(\.id) == [older.id, newer.id])
        #expect(state.rows(in: .doneRecently).map(\.id) == [second.id, first.id])
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }
}

// A clock a test moves on by hand.
final class JobListClock {
    var now: Date

    init(now: Date) { self.now = now }
}

nonisolated enum JobListFixture {
    // A job on its own watch, set to Done at the given time.
    static func done(_ coordinator: LibraryCoordinator, at date: Date) async throws -> JobRecord {
        let job = try await JobTaskFixture.job(coordinator)
        _ = try await JobService(coordinator: coordinator).setStage(job.id, to: .done)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: "UPDATE job SET doneAt = ? WHERE id = ?",
                arguments: [date.timeIntervalSince1970, job.id.uuidString])
        }
        return try #require(try await coordinator.read { try JobQueries.fetch(job.id, in: $0) })
    }

    @MainActor
    static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw JobListObservationTimeout()
    }
}

nonisolated struct JobListObservationTimeout: Error {}
