import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct PartsOverviewTests {
    @Test
    func similarPartsRetainExactOwnersAndOnlyOpenStagesAcrossRestart() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { date }))
        _ = try await coordinator.open()
        #expect(try await coordinator.read(PartsOverviewQueries.fetch).isEmpty)
        var expected: Set<UUID> = []
        for stage in JobStage.allCases {
            let job = try await JobTaskFixture.job(coordinator)
            _ = try await WatchService(coordinator: coordinator).update(
                job.watchID, .name("Watch \(stage.rawValue) Å時計"))
            for status in PartStatus.allCases {
                var draft = PartFixture.draft()
                draft.description = "Mainspring Å時計"
                draft.quantity = "7"
                draft.links = [
                    PartLinkDraft(url: "https://example.org/part"),
                    PartLinkDraft(url: "https://example.org/other"),
                ]
                let service = PartService(coordinator: coordinator)
                let part = try await service.save(draft, for: job.id, editing: nil)
                var edit = PartDraft(part: part)
                edit.status = status
                edit.statusReason = "Verified after inspection"
                edit.confirmsOnHand = true
                _ = try await service.save(edit, for: job.id, editing: part.id)
                if stage.isOpen { expected.insert(part.id) }
            }
            _ = try await JobService(coordinator: coordinator).setStage(job.id, to: stage)
        }
        let rows = try await coordinator.read(PartsOverviewQueries.fetch)
        #expect(rows.count == 10 && Set(rows.map(\.id)) == expected)
        #expect(Set(rows.map { $0.job.stage }) == [.inProgress, .waiting])
        for row in rows {
            #expect(row.part.jobID == row.job.id && row.job.watchID == row.watch.id)
            #expect(row.watch.name == "Watch \(row.job.stage.rawValue) Å時計")
            #expect(row.part.quantity == 7 && row.part.description == "Mainspring Å時計")
        }
        for status in PartStatus.allCases {
            #expect(rows.filter { $0.part.status == status }.count == 2)
        }
        #expect(rows.map(\.id) == rows.map(\.id).sorted { $0.uuidString < $1.uuidString })
        #expect(try await coordinator.read(PartQueries.fetchAll).count == 15)
        try await coordinator.close()
        let restarted = fixture.coordinator()
        _ = try await restarted.open()
        #expect(try await restarted.read(PartsOverviewQueries.fetch) == rows)
        let recentID = try #require(rows.last?.id)
        try await restarted.mutate { db, _, _ in
            try db.execute(
                sql: "UPDATE partRequirement SET updatedAt = ? WHERE id = ?",
                arguments: [date.addingTimeInterval(1).timeIntervalSince1970, recentID.uuidString])
        }
        #expect(try await restarted.read(PartsOverviewQueries.fetch).first?.id == recentID)
        try await restarted.close()
    }
}
