import Foundation
import GRDB
import Testing

@testable import Ure

struct PartListTests {
    @Test(.timeLimit(.minutes(1)))
    func theListGroupsPartsOnTheirWayWithSparesAndCountsWhatIsToBuy() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let open = try await JobTaskFixture.job(coordinator)
        let unwatched = try await JobService(coordinator: coordinator).start(
            for: nil, title: "New crystal")
        let done = try await JobTaskFixture.job(coordinator)
        let archived = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        let mainspring = try await service.add(named: "Mainspring", to: open.id)
        let crystal = try await service.add(named: "Crystal", to: unwatched.id)
        let gaskets = try await service.update(
            try await service.add(named: "Gaskets", to: open.id).id, .quantity("3"))
        _ = try await service.setStage(gaskets.id, to: .ordered)
        let crown = try await service.add(named: "Crown", to: open.id)
        _ = try await service.setStage(crown.id, to: .inHand)
        let fitted = try await service.add(named: "Hands", to: open.id)
        _ = try await service.setStage(fitted.id, to: .fitted)
        _ = try await service.add(named: "Strap", to: done.id)
        _ = try await service.add(named: "Stem", to: archived.id)
        let spare = try await service.add(named: "Crystal 30.0 mm", to: nil)
        let spareToBuy = try await service.add(named: "Mainspring 1.10", to: nil)
        _ = try await service.setStage(spareToBuy.id, to: .needed)
        _ = try await JobService(coordinator: coordinator).setStage(done.id, to: .done)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: "UPDATE job SET archivedAt = 1 WHERE id = ?",
                arguments: [archived.id.uuidString])
        }

        let list = PartListState(coordinator: coordinator)
        let observation = Task { await list.observe() }
        defer { observation.cancel() }
        try await waitUntil { !list.isLoading }
        // Fitted parts, parts of done jobs and parts of archived jobs stay on their job's page.
        #expect(
            Set(list.rows(in: .toBuy).map(\.id)) == [mainspring.id, crystal.id, spareToBuy.id])
        #expect(list.rows(in: .ordered).map(\.id) == [gaskets.id])
        #expect(Set(list.rows(in: .inHand).map(\.id)) == [crown.id, spare.id])
        #expect(list.toBuyCount == 3 && list.subtitle == "3 to buy · 1 ordered")

        let rows = Dictionary(uniqueKeysWithValues: list.rows.map { ($0.id, $0) })
        #expect(rows[spare.id].map(PartListWording.detail) == "Spare")
        #expect(rows[crystal.id].map(PartListWording.detail) == "No watch yet · New crystal")
        #expect(
            rows[gaskets.id].map(PartListWording.detail) == "Omega 0012–Å · Service movement · × 3")
        #expect(rows[mainspring.id]?.watch?.id == open.watchID && rows[spare.id]?.job == nil)

        // The search matches the part, its job and its watch.
        list.searchText = " crystal "
        #expect(Set(list.filteredRows.map(\.id)) == [crystal.id, spare.id])
        list.searchText = "service movement"
        #expect(Set(list.filteredRows.map(\.id)) == [mainspring.id, gaskets.id, crown.id])
        list.clearSearch()

        // The list follows each change.
        _ = try await service.advance(mainspring.id)
        try await waitUntil { list.subtitle == "2 to buy · 2 ordered" }
        _ = try await service.useSpare(spare.id, on: open.id)
        try await waitUntil { list.rows.first { $0.id == spare.id }?.job?.id == open.id }
        _ = try await service.remove(crystal.id)
        try await waitUntil { !list.contains(crystal.id) }
        #expect(list.toBuyCount == 1)
        observation.cancel()
        await observation.value
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aJobsPartsToBuyShowOnItsRow() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        _ = try await service.add(named: "Mainspring", to: job.id)
        let crystal = try await service.add(named: "Crystal", to: job.id)
        _ = try await service.add(named: "Crystal 30.0 mm", to: nil)
        let rows = try await coordinator.read { try JobListQueries.fetch($0, doneSince: .now) }
        #expect(rows.map(\.partsToBuy) == [2])
        _ = try await service.advance(crystal.id)
        let next = try await coordinator.read { try JobListQueries.fetch($0, doneSince: .now) }
        #expect(next.map(\.partsToBuy) == [1])
        try await coordinator.close()
    }
}

private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw PartListTimeout()
}

nonisolated private struct PartListTimeout: Error {}
