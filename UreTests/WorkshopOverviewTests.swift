import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct WorkshopOverviewTests {
    @Test
    func openStagesAggregateStepsAndWholePartRequirementsWithoutDuplicateJobs() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { date }))
        _ = try await coordinator.open()
        let jobs = JobService(coordinator: coordinator)
        let checklist = ChecklistService(coordinator: coordinator)
        let parts = PartService(coordinator: coordinator)
        var openIDs: Set<UUID> = []
        var closedIDs: Set<UUID> = []
        for stage in JobStage.allCases {
            let job = try await JobTaskFixture.job(coordinator)
            _ = try await checklist.save(
                [
                    ChecklistStep(id: UUID(), text: "Cleaning", isHeading: true),
                    ChecklistStep(id: UUID(), text: "Clean all parts", isTicked: true),
                    ChecklistStep(id: UUID(), text: "Fit the new mainspring"),
                    ChecklistStep(id: UUID(), text: "Regulate"),
                ], for: job.id)
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
            _ = try await jobs.setStage(job.id, to: stage)
            if stage == .waiting { _ = try await jobs.update(job.id, .waitingFor("A mainspring")) }
            if stage.isOpen { openIDs.insert(job.id) } else { closedIDs.insert(job.id) }
        }
        let rows = try await coordinator.read(WorkshopQueries.fetch)
        #expect(Set(rows.map(\.id)) == openIDs)
        #expect(rows.count == 2)
        #expect(Set(rows.map { $0.job.stage }) == [.inProgress, .waiting])
        for row in rows {
            #expect(row.watch.id == row.job.watchID)
            #expect(row.progress.doneCount == 1 && row.progress.stepCount == 3)
            #expect(row.progress.summary == "1 of 3 done")
            #expect(row.unresolvedPartCount == 2)
            #expect(row.updatedAt == date)
        }
        #expect(rows.first { $0.job.stage == .waiting }?.job.waitingFor == "A mainspring")
        let saved = try await coordinator.read(JobQueries.fetchAll)
        #expect(closedIDs.isSubset(of: Set(saved.map(\.id))))
        try await coordinator.close()
        let restarted = fixture.coordinator()
        _ = try await restarted.open()
        #expect(try await restarted.read(WorkshopQueries.fetch) == rows)
        try await restarted.close()
    }

    @Test
    func emptyAndHeadingOnlyProgressAndLatestChildDatesDetermineStableOrder() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 100)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { date }))
        _ = try await coordinator.open()
        #expect(try await coordinator.read(WorkshopQueries.fetch).isEmpty)
        let empty = try await JobTaskFixture.job(coordinator)
        let headed = try await JobTaskFixture.job(coordinator)
        let recent = try await JobTaskFixture.job(coordinator)
        let heading = try #require(
            try await ChecklistService(coordinator: coordinator).save(
                [ChecklistStep(id: UUID(), text: "Cleaning", isHeading: true)], for: headed.id
            ).first)
        let part = try await PartService(coordinator: coordinator).save(
            PartFixture.draft(), for: recent.id, editing: nil)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: "UPDATE checklistStep SET updatedAt = 200 WHERE id = ?",
                arguments: [heading.id.uuidString])
            try db.execute(
                sql: "UPDATE partRequirement SET updatedAt = 300 WHERE id = ?",
                arguments: [part.id.uuidString])
        }
        let rows = try await coordinator.read(WorkshopQueries.fetch)
        #expect(rows.map(\.id) == [recent.id, headed.id, empty.id])
        #expect(rows[0].updatedAt == Date(timeIntervalSince1970: 300))
        #expect(rows[1].progress.stepCount == 0 && rows[1].progress.summary == "No steps yet")
        #expect(rows[2].progress.stepCount == 0 && rows[2].unresolvedPartCount == 0)
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
                == [empty.id, headed.id, recent.id].sorted { $0.uuidString < $1.uuidString })
        try await coordinator.close()
    }
}
