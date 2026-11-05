import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct PartProcurementTests {
    private let clock = Date(timeIntervalSince1970: 1_778_307_200 + 21.0 / 4_194_304)

    @Test(arguments: PartStatus.allCases, PartStatus.allCases)
    func transitionsKeepTheCurrentMilestones(from: PartStatus, to: PartStatus)
        async throws
    {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = clock
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { clock }))
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        let needed = try await service.save(PartFixture.draft(), for: job.id, editing: nil)
        let prior = try await change(needed, to: from, service: service)
        let next = try await change(prior, to: to, service: service)
        #expect(next.record.status == to && next.record.quantity == 1)
        #expect(try await coordinator.read(PartQueries.fetchAll) == [next])
        #expect(try await coordinator.read(JobQueries.fetchAll) == [job])
        if from == to { #expect(next == prior) }
        switch to {
        case .needed:
            #expect(next.record.orderedAt == nil && next.record.arrivedAt == nil)
            #expect(next.record.installedAt == nil && next.record.cancelledAt == nil)
        case .ordered:
            #expect(next.record.orderedAt == clock && next.record.arrivedAt == nil)
            #expect(next.record.installedAt == nil && next.record.cancelledAt == nil)
        case .arrived:
            #expect(next.record.arrivedAt == clock && next.record.installedAt == nil)
            #expect(next.record.cancelledAt == nil)
        case .installed:
            #expect(next.record.arrivedAt == clock && next.record.installedAt == clock)
            #expect(next.record.cancelledAt == nil)
        case .cancelled:
            #expect(next.record.orderedAt == nil && next.record.arrivedAt == nil)
            #expect(next.record.installedAt == nil && next.record.cancelledAt == clock)
        }
        try await coordinator.close()
    }

    @Test
    func onHandCreationAndDirectInstallationRequireExplicitAvailability() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = clock
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { clock }))
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        for status in [PartStatus.ordered, .installed, .cancelled] {
            var invalid = PartFixture.draft()
            invalid.status = status
            invalid.confirmsOnHand = true
            await #expect(throws: PartValidationError.self) {
                try await service.save(invalid, for: job.id, editing: nil)
            }
        }
        var draft = PartFixture.draft()
        draft.status = .arrived
        draft.quantity = "5"
        let onHand = try await service.save(draft, for: job.id, editing: nil)
        #expect(onHand.record.arrivedAt == clock && onHand.record.installedAt == nil)
        #expect(onHand.record.quantity == 5)
        let fitted = try await change(onHand, to: .installed, service: service)
        #expect(fitted.record.arrivedAt == clock && fitted.record.installedAt == clock)
        for status in [PartStatus.needed, .ordered, .cancelled] {
            let needed = try await service.save(PartFixture.draft(), for: job.id, editing: nil)
            let prior = try await change(needed, to: status, service: service)
            var install = PartDraft(part: prior)
            install.status = .installed
            install.statusReason = "Reinstate this lot"
            await #expect(throws: PartValidationError.self) {
                try await service.save(install, for: job.id, editing: prior.id)
            }
            #expect(try await coordinator.read { try PartQueries.fetch(prior.id, in: $0) } == prior)
            install.confirmsOnHand = true
            let saved = try await service.save(install, for: job.id, editing: prior.id)
            #expect(saved.record.arrivedAt == clock && saved.record.installedAt == clock)
        }
        try await coordinator.close()
    }

    @Test(arguments: [
        (PartStatus.ordered, PartStatus.needed), (.arrived, .needed), (.arrived, .ordered),
        (.installed, .needed), (.installed, .ordered), (.installed, .arrived),
        (.needed, .cancelled), (.ordered, .cancelled), (.arrived, .cancelled),
        (.installed, .cancelled),
        (.cancelled, .needed), (.cancelled, .ordered), (.cancelled, .arrived),
        (.cancelled, .installed),
    ])
    func correctionsAndCancellationRequireReason(from: PartStatus, to: PartStatus) async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = clock
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { clock }))
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        let needed = try await service.save(PartFixture.draft(), for: job.id, editing: nil)
        let prior = try await change(needed, to: from, service: service)
        var draft = PartDraft(part: prior)
        draft.status = to
        draft.confirmsOnHand = true
        draft.statusReason = " \n "
        await #expect(throws: PartValidationError.self) {
            try await service.save(draft, for: job.id, editing: prior.id)
        }
        #expect(try await coordinator.read(PartQueries.fetchAll) == [prior])
        draft.statusReason = "  Corrected bench record Å時計  "
        let corrected = try await service.save(draft, for: job.id, editing: prior.id)
        #expect(corrected.record.statusReason == "Corrected bench record Å時計")
        try await coordinator.close()
    }

    @Test
    func orderReferenceSurvivesLinkRemovalCorrectionsCancellationAndRestart() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = clock
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { clock }))
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        var draft = PartFixture.draft()
        draft.links = [PartLinkDraft(url: "https://example.org/part?code=0012")]
        let needed = try await service.save(draft, for: job.id, editing: nil)
        var order = PartDraft(part: needed)
        order.status = .ordered
        order.orderReference = "  000042–Å/03  "
        let ordered = try await service.save(order, for: job.id, editing: needed.id)
        #expect(ordered.record.orderReference == "000042–Å/03")
        var edit = PartDraft(part: ordered)
        edit.links = []
        let removed = try await service.save(edit, for: job.id, editing: ordered.id)
        #expect(removed.links.isEmpty && removed.record.orderReference == "000042–Å/03")
        let installed = try await change(removed, to: .installed, service: service)
        let corrected = try await change(installed, to: .ordered, service: service)
        #expect(
            corrected.record.orderReference == "000042–Å/03"
                && corrected.record.orderedAt == clock)
        #expect(corrected.record.arrivedAt == nil && corrected.record.installedAt == nil)
        let cancelled = try await change(corrected, to: .cancelled, service: service)
        #expect(cancelled.record.orderReference == "000042–Å/03")
        try await coordinator.close()
        let reopened = fixture.coordinator()
        _ = try await reopened.open()
        #expect(try await reopened.read(PartQueries.fetchAll) == [cancelled])
        let serviceAfterRestart = PartService(coordinator: reopened)
        let restored = try await change(cancelled, to: .ordered, service: serviceAfterRestart)
        #expect(restored.record.orderReference == "000042–Å/03")
        let reset = try await change(restored, to: .needed, service: serviceAfterRestart)
        #expect(reset.record.orderReference == nil && reset.record.orderedAt == nil)
        try await reopened.close()
    }

    @Test
    func failedWritesRollBackPartAndLinkWritesAndStaleStatusIsRejected() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = clock
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { clock }))
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        var draft = PartFixture.draft()
        draft.links = [PartLinkDraft(url: "https://example.org/part")]
        let needed = try await service.save(draft, for: job.id, editing: nil)
        var order = PartDraft(part: needed)
        order.status = .ordered
        order.links[0].url = "https://example.org/changed"
        order.orderReference = "000012"
        try await JobTaskFixture.failWrites(coordinator, on: "partRequirement")
        await #expect(throws: DatabaseError.self) {
            try await service.save(order, for: job.id, editing: needed.id)
        }
        var onHand = PartFixture.draft()
        onHand.status = .arrived
        await #expect(throws: DatabaseError.self) {
            try await service.save(onHand, for: job.id, editing: nil)
        }
        #expect(try await coordinator.read(PartQueries.fetchAll) == [needed])
        try await JobTaskFixture.allowWrites(coordinator, on: "partRequirement")
        let ordered = try await service.save(order, for: job.id, editing: needed.id)
        await #expect(throws: PartError.staleStatus) {
            try await service.save(order, for: job.id, editing: needed.id)
        }
        #expect(try await coordinator.read(PartQueries.fetchAll) == [ordered])
        #expect(
            try await service.save(PartDraft(part: ordered), for: job.id, editing: ordered.id)
                == ordered)
        try await coordinator.close()
    }

    @Test
    func hiddenReasonsAreNotSavedAndValidationReportsAllAffectedFields() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = clock
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { clock }))
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        let needed = try await service.save(PartFixture.draft(), for: job.id, editing: nil)
        let ordered = try await change(needed, to: .ordered, service: service)
        var draft = PartDraft(part: ordered)
        draft.status = .cancelled
        draft.description = ""
        do {
            _ = try await service.save(draft, for: job.id, editing: ordered.id)
            Issue.record("Invalid description and missing cancellation reason must fail together")
        } catch let error as PartValidationError {
            #expect(error.fields[.description] != nil && error.fields[.statusReason] != nil)
        }
        draft.status = .installed
        do {
            _ = try await service.save(draft, for: job.id, editing: ordered.id)
            Issue.record("Invalid description and missing on-hand confirmation must fail together")
        } catch let error as PartValidationError {
            #expect(error.fields[.description] != nil && error.fields[.onHand] != nil)
        }
        draft.description = ordered.record.description
        draft.statusReason = "Supplier out of stock"
        draft.status = .arrived
        let arrived = try await service.save(draft, for: job.id, editing: ordered.id)
        #expect(arrived.record.statusReason == nil)
        try await coordinator.close()
    }

    @Test(arguments: PartStatus.allCases)
    func aDoneJobKeepsItsProcurementAndChecklistAndTakesChanges(status: PartStatus) async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = clock
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { clock }))
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        let steps = try await ChecklistService(coordinator: coordinator).save(
            [ChecklistStep(id: UUID(), text: "Fit the new mainspring")], for: job.id)
        let needed = try await service.save(PartFixture.draft(), for: job.id, editing: nil)
        let part = try await change(needed, to: status, service: service)
        _ = try await JobService(coordinator: coordinator).setStage(job.id, to: .done)
        #expect(try await coordinator.read(PartQueries.fetchAll) == [part])
        #expect(try await coordinator.read(ChecklistQueries.fetchAll) == steps)
        var correction = PartDraft(part: part)
        correction.status = .installed
        correction.confirmsOnHand = true
        correction.statusReason = "Fitted after the job was done"
        let fitted = try await service.save(correction, for: job.id, editing: part.id)
        #expect(fitted.record.status == .installed)
        _ = try await service.save(PartFixture.draft(), for: job.id, editing: nil)
        #expect(try await coordinator.read(PartQueries.fetchAll).count == 2)
        try await coordinator.close()
    }

    @Test
    func forwardMigrationPreservesLinksOrderCoverAndOriginals() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let clock = clock
        let coordinator = LibraryCoordinator(
            root: fixture.root, dependencies: LibraryDependencies(now: { clock }))
        let before = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let material = MaterialService(coordinator: coordinator)
        let source = try fixture.source(type: .png)
        let bytes = try Data(contentsOf: source)
        let photo = try await material.importFiles([source], for: .job(job.id))[0].outcome.get()
        try await material.setCover(photo.id, for: job.watchID)
        let watch = try #require(try await coordinator.read(WatchQueries.fetchAll).first)
        let checklist = ChecklistService(coordinator: coordinator)
        let first = ChecklistStep(id: UUID(), text: "Clean all parts", isTicked: true)
        let second = ChecklistStep(id: UUID(), text: "Fit the new mainspring")
        _ = try await checklist.save([first, second], for: job.id)
        let steps = try await checklist.save([second, first], for: job.id)
        var draft = PartFixture.draft()
        draft.links = [PartLinkDraft(url: "https://example.org/part")]
        let part = try await PartService(coordinator: coordinator).save(
            draft, for: job.id, editing: nil)
        try await coordinator.mutate { db, _, _ in
            try PartProcurementMigrationFixture.removeProcurement(in: db)
        }
        try await coordinator.close()
        let reopened = LibraryCoordinator(
            root: fixture.root, dependencies: LibraryDependencies(now: { clock }))
        let after = try await reopened.open()
        #expect(after.generationID != before.generationID)
        #expect(try await reopened.read(PartQueries.fetchAll) == [part])
        #expect(try await reopened.read(JobQueries.fetchAll) == [job])
        #expect(try await reopened.read(ChecklistQueries.fetchAll) == steps)
        #expect(try await reopened.read(WatchQueries.fetchAll) == [watch])
        #expect(try await reopened.read(MaterialQueries.fetchAll) == [photo])
        #expect(
            try Data(contentsOf: await reopened.originalURL(for: try #require(photo.asset).id))
                == bytes)
        let ordered = try await change(
            part, to: .ordered, service: PartService(coordinator: reopened))
        #expect(ordered.record.orderedAt == clock && ordered.links == part.links)
        try await reopened.close()
    }

    @Test
    func arrivalAndInstallationKeepTheirOwnDatesAcrossCorrections() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let arrivalDate = firstDate.addingTimeInterval(3600)
        let installDate = arrivalDate.addingTimeInterval(3600)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { firstDate }))
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        let needed = try await service.save(PartFixture.draft(), for: job.id, editing: nil)
        let ordered = try await change(needed, to: .ordered, service: service)
        try await coordinator.close()
        let arrivalLibrary = fixture.coordinator(
            dependencies: LibraryDependencies(now: { arrivalDate }))
        _ = try await arrivalLibrary.open()
        let arrived = try await change(
            ordered, to: .arrived, service: PartService(coordinator: arrivalLibrary))
        #expect(arrived.record.orderedAt == firstDate && arrived.record.arrivedAt == arrivalDate)
        try await arrivalLibrary.close()
        let installationLibrary = fixture.coordinator(
            dependencies: LibraryDependencies(now: { installDate }))
        _ = try await installationLibrary.open()
        let installationService = PartService(coordinator: installationLibrary)
        let installed = try await change(arrived, to: .installed, service: installationService)
        #expect(
            installed.record.orderedAt == firstDate && installed.record.arrivedAt == arrivalDate)
        #expect(installed.record.installedAt == installDate)
        let corrected = try await change(installed, to: .arrived, service: installationService)
        #expect(corrected.record.arrivedAt == arrivalDate && corrected.record.installedAt == nil)
        try await installationLibrary.close()
    }

    private func change(_ part: PartRequirement, to status: PartStatus, service: PartService)
        async throws -> PartRequirement
    {
        var draft = PartDraft(part: part)
        draft.status = status
        draft.statusReason = "Corrected bench record"
        draft.confirmsOnHand = true
        return try await service.save(draft, for: part.record.jobID, editing: part.id)
    }
}

nonisolated enum PartProcurementMigrationFixture {
    static func removeProcurement(in db: Database) throws {
        try TaskPartMigrationFixture.removeLinks(in: db)
        for column in [
            "orderedAt", "arrivedAt", "installedAt", "cancelledAt", "supplierSnapshot",
            "orderReference", "statusReason",
        ] {
            try db.execute(sql: "ALTER TABLE partRequirement DROP COLUMN \(column)")
        }
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v15-part-procurement'")
        try db.execute(
            sql: """
                CREATE TABLE activityEvent_old (
                    id TEXT PRIMARY KEY, jobID TEXT NOT NULL REFERENCES job(id),
                    kind TEXT NOT NULL CHECK(kind IN ('Job stage changed', 'Watch condition changed', 'Task status changed')),
                    occurredAt DOUBLE NOT NULL, ordering INTEGER NOT NULL UNIQUE CHECK(ordering > 0),
                    priorValue TEXT NOT NULL CHECK(json_valid(priorValue)),
                    nextValue TEXT NOT NULL CHECK(json_valid(nextValue)))
                """)
        try db.execute(sql: "INSERT INTO activityEvent_old SELECT * FROM activityEvent")
        try db.drop(table: "activityEvent")
        try db.rename(table: "activityEvent_old", to: "activityEvent")
        try db.create(
            index: "activityEvent_jobID_ordering", on: "activityEvent",
            columns: ["jobID", "ordering"])
    }
}
