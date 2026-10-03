import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct WorkshopOverviewTests {
    @Test
    func openStagesAggregateTasksAndWholePartRequirementsWithoutDuplicateJobs() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { date }))
        _ = try await coordinator.open()
        let jobs = JobService(coordinator: coordinator)
        let tasks = JobTaskService(coordinator: coordinator)
        let parts = PartService(coordinator: coordinator)
        var openIDs: Set<UUID> = []
        var closedIDs: Set<UUID> = []
        for stage in JobStage.allCases {
            let job = try await JobTaskFixture.job(coordinator)
            for status in JobTaskStatus.allCases {
                _ = try await tasks.save(JobTaskFixture.draft(status), for: job.id, editing: nil)
            }
            for status in PartStatus.allCases {
                var draft = PartFixture.draft()
                draft.quantity = "7"
                let part = try await parts.save(draft, for: job.id, editing: nil)
                if status != .needed {
                    var edit = PartDraft(part: part)
                    edit.status = status
                    edit.statusReason = "Corrected after inspection"
                    edit.confirmsOnHand = true
                    _ = try await parts.save(edit, for: job.id, editing: part.id)
                }
            }
            var transition = JobTransitionDraft(stage: stage)
            transition.waitingReason = "Mainspring on order"
            transition.outcome = "Reviewed"
            transition.cancellationReason = "Stopped"
            transition.unfinishedTasksReason = "Retained tasks"
            transition.unfinishedPartsReason = "Retained requirements"
            _ = try await jobs.transition(job.id, using: transition)
            if stage.isOpen { openIDs.insert(job.id) } else { closedIDs.insert(job.id) }
        }
        let rows = try await coordinator.read(WorkshopQueries.fetch)
        #expect(Set(rows.map(\.id)) == openIDs)
        #expect(rows.count == 4)
        #expect(Set(rows.map { $0.job.stage }) == [.planned, .inProgress, .waiting, .ready])
        for row in rows {
            #expect(row.watch.id == row.job.watchID)
            #expect(row.progress.doneCount == 1 && row.progress.countedCount == 4)
            #expect(row.progress.skippedCount == 1 && row.progress.percentage == 25)
            #expect(row.unresolvedPartCount == 2)
            #expect(row.updatedAt == date)
        }
        #expect(rows.first { $0.job.stage == .waiting }?.job.waitingReason == "Mainspring on order")
        let saved = try await coordinator.read(JobQueries.fetchAll)
        #expect(closedIDs.isSubset(of: Set(saved.map(\.id))))
        try await coordinator.close()
        let restarted = fixture.coordinator()
        _ = try await restarted.open()
        #expect(try await restarted.read(WorkshopQueries.fetch) == rows)
        try await restarted.close()
    }

    @Test
    func emptyAndSkippedProgressAndLatestChildDatesDetermineStableOrder() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 100)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { date }))
        _ = try await coordinator.open()
        #expect(try await coordinator.read(WorkshopQueries.fetch).isEmpty)
        let empty = try await JobTaskFixture.job(coordinator)
        let skipped = try await JobTaskFixture.job(coordinator)
        let recent = try await JobTaskFixture.job(coordinator)
        let task = try await JobTaskService(coordinator: coordinator).save(
            JobTaskFixture.draft(.skipped), for: skipped.id, editing: nil)
        let part = try await PartService(coordinator: coordinator).save(
            PartFixture.draft(), for: recent.id, editing: nil)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: "UPDATE jobTask SET updatedAt = 200 WHERE id = ?",
                arguments: [task.id.uuidString])
            try db.execute(
                sql: "UPDATE partRequirement SET updatedAt = 300 WHERE id = ?",
                arguments: [part.id.uuidString])
        }
        let rows = try await coordinator.read(WorkshopQueries.fetch)
        #expect(rows.map(\.id) == [recent.id, skipped.id, empty.id])
        #expect(rows[0].updatedAt == Date(timeIntervalSince1970: 300))
        #expect(rows[1].progress.percentage == nil && rows[1].progress.skippedCount == 1)
        #expect(rows[2].progress.percentage == nil && rows[2].unresolvedPartCount == 0)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: "UPDATE job SET updatedAt = 400 WHERE id = ?", arguments: [empty.id.uuidString]
            )
        }
        #expect(try await coordinator.read(WorkshopQueries.fetch).first?.id == empty.id)
        try await coordinator.mutate { db, _, _ in
            try db.execute(sql: "UPDATE job SET updatedAt = 500")
        }
        let tied = try await coordinator.read(WorkshopQueries.fetch)
        #expect(
            tied.map(\.id)
                == [empty.id, skipped.id, recent.id].sorted { $0.uuidString < $1.uuidString })
        try await coordinator.close()
    }
}
