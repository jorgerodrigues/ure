import Foundation
import GRDB
import Synchronization
import Testing

@testable import Ure

nonisolated struct PartServiceTests {
    @Test
    func aPartTakesOneLineAndGoesToTheEndOfItsJob() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let other = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)

        let mainspring = try await service.add(named: "  Mainspring GR 3800 ", to: job.id)
        let crystal = try await service.add(named: "Crystal", to: job.id)
        let crown = try await service.add(named: "Crown", to: other.id)
        let gasket = try await service.add(named: "Gasket", to: job.id)
        #expect(mainspring.name == "Mainspring GR 3800" && mainspring.jobID == job.id)
        #expect(mainspring.stage == .needed && mainspring.quantity == 1)
        #expect(mainspring.orderedAt == nil && mainspring.inHandAt == nil)
        #expect(mainspring.description == nil && mainspring.notes.isEmpty)
        #expect([mainspring, crystal, gasket].map(\.position) == [0, 1, 2])
        #expect(crown.position == 0)
        #expect(try await service.add(named: " \n", to: job.id).name == PartService.newName)
        #expect(
            try await coordinator.read(PartQueries.fetchAll).filter { $0.jobID == job.id }.map(
                \.name) == ["Mainspring GR 3800", "Crystal", "Gasket", "New Part"])

        // A part of an archived job can't be added or changed. A Done job takes parts.
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: "UPDATE job SET archivedAt = 1 WHERE id = ?", arguments: [other.id.uuidString])
        }
        await #expect(throws: ArchiveError.archived) {
            try await service.add(named: "Hands", to: other.id)
        }
        await #expect(throws: ArchiveError.archived) { try await service.advance(crown.id) }
        _ = try await JobService(coordinator: coordinator).setStage(job.id, to: .done)
        #expect(try await service.add(named: "Hands", to: job.id).position == 4)
        try await coordinator.close()
    }

    @Test
    func theStateMovesOnWithItsDayAndFittedIsTheLast() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = PartClock()
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: clock.now))
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        let part = try await service.add(named: "Mainspring", to: job.id)

        clock.set(1_000)
        let ordered = try await service.advance(part.id)
        #expect(ordered.prior == PartStageValue(stage: .needed))
        #expect(ordered.part.stage == .ordered && ordered.part.orderedAt == clock.date(1_000))
        clock.set(2_000)
        let inHand = try await service.advance(part.id).part
        #expect(inHand.stage == .inHand && inHand.orderedAt == clock.date(1_000))
        #expect(inHand.inHandAt == clock.date(2_000) && inHand.fittedAt == nil)
        clock.set(3_000)
        let fitted = try await service.advance(part.id)
        #expect(fitted.part.stage == .fitted && fitted.part.fittedAt == clock.date(3_000))
        #expect(fitted.prior == PartStageValue(part: inHand))
        clock.set(4_000)
        let again = try await service.advance(part.id)
        #expect(again.part == fitted.part && again.prior == PartStageValue(part: fitted.part))

        // Going back keeps the days the part still has reached and clears the rest.
        let back = try await service.setStage(part.id, to: .ordered).part
        #expect(back.orderedAt == clock.date(1_000) && back.inHandAt == nil && back.fittedAt == nil)
        let needed = try await service.setStage(part.id, to: .needed).part
        #expect(needed.orderedAt == nil && needed.inHandAt == nil && needed.fittedAt == nil)
        // Skipping a state records only the day of the state reached.
        clock.set(5_000)
        let skipped = try await service.setStage(part.id, to: .inHand).part
        #expect(skipped.orderedAt == nil && skipped.inHandAt == clock.date(5_000))

        // Undo puts back a state exactly, with its days.
        let restored = try await service.restoreStage(
            part.id, to: PartStageValue(part: fitted.part))
        #expect(PartStageValue(part: restored) == PartStageValue(part: fitted.part))

        // The library refuses a day that the state has not reached.
        await #expect(throws: DatabaseError.self) {
            try await coordinator.mutate { db, _, _ in
                try db.execute(
                    sql: "UPDATE part SET stage = 'Needed' WHERE id = ?",
                    arguments: [part.id.uuidString])
            }
        }
        try await coordinator.close()
    }

    @Test
    func aSpareIsInHandAndGoesToAJobOnlyFromTheDrawer() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = PartClock()
        clock.set(7_000)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: clock.now))
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        _ = try await service.add(named: "Mainspring", to: job.id)

        let spare = try await service.add(named: "", to: nil)
        #expect(spare.isSpare && spare.name == PartService.newName)
        #expect(spare.stage == .inHand && spare.inHandAt == clock.date(7_000))

        let used = try await service.useSpare(spare.id, on: job.id)
        #expect(used.jobID == job.id && used.position == 1 && used.stage == .inHand)
        #expect(used.inHandAt == clock.date(7_000))
        await #expect(throws: PartError.spareTaken) {
            try await service.useSpare(spare.id, on: job.id)
        }
        // Undo puts the spare back in the drawer.
        let back = try await service.place(spare.id, at: PartPlacement(part: spare))
        #expect(back.isSpare && back.position == spare.position)

        // A spare still to buy can't go on a job yet.
        let needed = try await service.setStage(spare.id, to: .needed).part
        #expect(needed.isSpare)
        await #expect(throws: PartError.spareTaken) {
            try await service.useSpare(spare.id, on: job.id)
        }
        try await coordinator.close()
    }

    @Test
    func eachFactSavesOnItsOwnAndRefusesWhatItDoesNotTake() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        let part = try await service.add(named: "Crystal", to: job.id)

        #expect(
            try await service.update(part.id, .name(" Crystal 30.0 mm ")).name == "Crystal 30.0 mm")
        await #expect(throws: PartValidationError.self) {
            try await service.update(part.id, .name("  "))
        }
        #expect(
            try await service.update(part.id, .description(" Domed sapphire ")).description
                == "Domed sapphire")
        #expect(try await service.update(part.id, .description(" ")).description == nil)
        #expect(try await service.update(part.id, .quantity(" 2 ")).quantity == 2)
        #expect(try await service.update(part.id, .quantity("٣")).quantity == 3)
        for text in ["0", "-1", "1.5", "two", "", "½"] {
            await #expect(throws: PartError.invalidQuantity, "\(text)") {
                try await service.update(part.id, .quantity(text))
            }
        }
        let notes = "From Cousins, 3 November.\n  Keep the old one.  "
        let noted = try await service.update(part.id, .notes(notes))
        #expect(noted.notes == notes && noted.quantity == 3 && noted.name == "Crystal 30.0 mm")
        // A value already saved changes nothing, not even the edit time.
        #expect(try await service.update(part.id, .notes(notes)) == noted)
        // Search finds the part by what its notes say.
        #expect(
            try await coordinator.read { try SearchQueries.fetch("keep the old one", in: $0) }.map(
                \.recordID) == [part.id])
        try await coordinator.close()
    }

    @Test
    func aRemovedPartComesBackWithItsLinks() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        let part = try await service.update(
            try await service.add(named: "Mainspring", to: job.id).id, .notes("Keep this"))
        let link = PartLink(
            id: UUID(), partID: part.id, position: 0, url: "https://example.org/gr3800",
            createdAt: Date(timeIntervalSince1970: 30), updatedAt: Date(timeIntervalSince1970: 31))
        try await coordinator.mutate { db, _, _ in try link.insert(db) }

        let removed = try await service.remove(part.id)
        #expect(removed.part == part && removed.links == [link])
        #expect(try await coordinator.read(PartQueries.library) == PartLibrary())
        let restored = try await service.restore(removed)
        #expect(restored == part)
        #expect(
            try await coordinator.read(PartQueries.library)
                == PartLibrary(parts: [part], links: [part.id: [link]]))
        #expect(
            try await coordinator.read { try SearchQueries.fetch("keep this", in: $0) }.map(
                \.recordID) == [part.id])
        try await coordinator.close()
    }

    @Test
    @MainActor
    func savedLinksOpenOnlyWhenAskedAndSayWhenTheyCannot() throws {
        let opened = OpenedLinks()
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        let service = PartService(coordinator: coordinator) { url in
            opened.urls.append(url)
            return true
        }
        let link = PartLink(
            id: UUID(), partID: UUID(), position: 0, url: "https://example.org/gr3800",
            createdAt: .now, updatedAt: .now)
        try service.open(link)
        #expect(opened.urls.map(\.absoluteString) == ["https://example.org/gr3800"])
        let broken = PartLink(
            id: UUID(), partID: UUID(), position: 0, url: "example", createdAt: .now,
            updatedAt: .now)
        #expect(throws: LinkError.invalidURL) { try service.open(broken) }
        let closed = PartService(coordinator: coordinator) { _ in false }
        #expect(throws: LinkError.browserUnavailable) { try closed.open(link) }
    }
}

// A clock a test sets, so each state's day is known.
nonisolated final class PartClock: Sendable {
    private let seconds = Mutex<Double>(1_700_000_000)

    var now: @Sendable () -> Date {
        { [self] in seconds.withLock { Date(timeIntervalSince1970: $0) } }
    }

    func set(_ offset: Double) { seconds.withLock { $0 = 1_700_000_000 + offset } }

    func date(_ offset: Double) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + offset) }
}

// The links a test's browser was asked to open.
final class OpenedLinks {
    var urls: [URL] = []
}
