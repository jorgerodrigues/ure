import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct PartProcurementTests {
    private let clock = Date(timeIntervalSince1970: 1_778_307_200 + 21.0 / 4_194_304)

    @Test(arguments: PartStatus.allCases, PartStatus.allCases)
    func transitionsPreserveHistoryAndCurrentMilestones(from: PartStatus, to: PartStatus)
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
        let before = try await coordinator.read(ActivityQueries.fetchAll)
        let next = try await change(prior, to: to, service: service)
        let events = try await coordinator.read(ActivityQueries.fetchAll)
        #expect(next.record.status == to && next.record.quantity == 1)
        #expect(try await coordinator.read(PartQueries.fetchAll) == [next])
        #expect(try await coordinator.read(JobQueries.fetchAll) == [job])
        if from == to {
            #expect(next == prior && events == before)
        } else {
            #expect(events.count == before.count + 1)
            #expect(events.last?.kind == .partStatusChanged)
            #expect(events.last?.priorValue == .part(PartProcurementValue(part: prior.record)))
            #expect(events.last?.nextValue == .part(PartProcurementValue(part: next.record)))
            #expect(events.last?.occurredAt == clock)
        }
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
        let events = try await coordinator.read(ActivityQueries.fetchAll)
        #expect(
            events.first?.priorValue
                == .part(PartProcurementValue(part: onHand.record, isNew: true)))
        #expect(events.first?.nextValue == .part(PartProcurementValue(part: onHand.record)))
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
        let events = try await coordinator.read(ActivityQueries.fetchAll)
        var draft = PartDraft(part: prior)
        draft.status = to
        draft.confirmsOnHand = true
        draft.statusReason = " \n "
        await #expect(throws: PartValidationError.self) {
            try await service.save(draft, for: job.id, editing: prior.id)
        }
        #expect(try await coordinator.read(PartQueries.fetchAll) == [prior])
        #expect(try await coordinator.read(ActivityQueries.fetchAll) == events)
        draft.statusReason = "  Corrected bench record Å時計  "
        let corrected = try await service.save(draft, for: job.id, editing: prior.id)
        #expect(corrected.record.statusReason == "Corrected bench record Å時計")
        try await coordinator.close()
    }

    @Test
    func supplierSnapshotSurvivesEditsRemovalCorrectionsCancellationAndRestart() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = clock
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { clock }))
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        var draft = PartFixture.draft()
        var option = PartLinkDraft(url: "https://example.org/part?code=0012")
        option.supplierName = "Supplier Å時計"
        option.title = "Spring for caliber 123"
        option.supplierStockCode = "00012-A/03"
        option.price = "0012.3400"
        option.currency = "dkk"
        option.notes = "Original sealed lot"
        draft.links = [option]
        draft.selectedLinkID = option.id
        let needed = try await service.save(draft, for: job.id, editing: nil)
        var order = PartDraft(part: needed)
        order.status = .ordered
        order.orderReference = "  000042–Å/03  "
        let ordered = try await service.save(order, for: job.id, editing: needed.id)
        let snapshot = try #require(ordered.record.supplierSnapshot)
        #expect(snapshot == PartSupplierSnapshot(link: ordered.links[0]))
        #expect(snapshot.price == "0012.3400" && snapshot.currency == "DKK")
        #expect(ordered.record.orderReference == "000042–Å/03")
        var edit = PartDraft(part: ordered)
        edit.links[0].supplierName = "Changed supplier"
        edit.links[0].url = "https://example.net/changed"
        edit.links[0].price = "99"
        let changed = try await service.save(edit, for: job.id, editing: ordered.id)
        #expect(changed.record.supplierSnapshot == snapshot)
        edit = PartDraft(part: changed)
        edit.links = []
        edit.selectedLinkID = nil
        let removed = try await service.save(edit, for: job.id, editing: changed.id)
        #expect(removed.record.supplierSnapshot == snapshot)
        let installed = try await change(removed, to: .installed, service: service)
        let corrected = try await change(installed, to: .ordered, service: service)
        #expect(
            corrected.record.supplierSnapshot == snapshot && corrected.record.orderedAt == clock)
        #expect(corrected.record.arrivedAt == nil && corrected.record.installedAt == nil)
        let cancelled = try await change(corrected, to: .cancelled, service: service)
        #expect(cancelled.record.supplierSnapshot == snapshot)
        #expect(cancelled.record.orderReference == ordered.record.orderReference)
        let events = try await coordinator.read(ActivityQueries.fetchAll)
        #expect(events.last?.priorValue == .part(PartProcurementValue(part: corrected.record)))
        try await coordinator.close()
        let reopened = fixture.coordinator()
        _ = try await reopened.open()
        #expect(try await reopened.read(PartQueries.fetchAll) == [cancelled])
        #expect(try await reopened.read(ActivityQueries.fetchAll) == events)
        let serviceAfterRestart = PartService(coordinator: reopened)
        let restored = try await change(cancelled, to: .ordered, service: serviceAfterRestart)
        #expect(restored.record.supplierSnapshot == snapshot)
        #expect(restored.record.orderReference == ordered.record.orderReference)
        let reset = try await change(restored, to: .needed, service: serviceAfterRestart)
        #expect(reset.record.supplierSnapshot == nil && reset.record.orderReference == nil)
        let reordered = try await change(reset, to: .ordered, service: serviceAfterRestart)
        #expect(reordered.record.supplierSnapshot == nil)
        try await reopened.close()
    }

    @Test
    func historyFailureRollsBackPartAndSupplierWritesAndStaleStatusIsRejected() async throws {
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
        order.links[0].supplierName = "New supplier"
        order.selectedLinkID = order.links[0].id
        order.orderReference = "000012"
        try await JobTaskFixture.failEvents(coordinator)
        await #expect(throws: DatabaseError.self) {
            try await service.save(order, for: job.id, editing: needed.id)
        }
        var onHand = PartFixture.draft()
        onHand.status = .arrived
        await #expect(throws: DatabaseError.self) {
            try await service.save(onHand, for: job.id, editing: nil)
        }
        #expect(try await coordinator.read(PartQueries.fetchAll) == [needed])
        #expect(try await coordinator.read(ActivityQueries.fetchAll).isEmpty)
        try await coordinator.mutate { db, _, _ in try db.execute(sql: "DROP TRIGGER failTaskEvent")
        }
        let ordered = try await service.save(order, for: job.id, editing: needed.id)
        await #expect(throws: PartError.staleStatus) {
            try await service.save(order, for: job.id, editing: needed.id)
        }
        #expect(try await coordinator.read(PartQueries.fetchAll) == [ordered])
        #expect(try await coordinator.read(ActivityQueries.fetchAll).count == 1)
        #expect(
            try await service.save(PartDraft(part: ordered), for: job.id, editing: ordered.id)
                == ordered)
        try await coordinator.close()
    }

    @Test
    func restorationKeepsUnknownSupplierButFirstOrderCapturesSelectedOption() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = clock
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { clock }))
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        var draft = PartFixture.draft()
        draft.links = [PartLinkDraft(url: "https://example.org/later-choice")]
        let needed = try await service.save(draft, for: job.id, editing: nil)
        var order = PartDraft(part: needed)
        order.status = .ordered
        order.orderReference = "PO-1"
        let ordered = try await service.save(order, for: job.id, editing: needed.id)
        #expect(ordered.record.supplierSnapshot == nil)
        var selection = PartDraft(part: ordered)
        selection.selectedLinkID = ordered.links[0].id
        let selected = try await service.save(selection, for: job.id, editing: ordered.id)
        #expect(selected.record.supplierSnapshot == nil)
        let cancelled = try await change(selected, to: .cancelled, service: service)
        let restored = try await change(cancelled, to: .ordered, service: service)
        #expect(restored.record.supplierSnapshot == nil && restored.record.orderReference == "PO-1")
        let cancelledAgain = try await change(restored, to: .cancelled, service: service)
        let arrived = try await change(cancelledAgain, to: .arrived, service: service)
        let recancelled = try await change(arrived, to: .cancelled, service: service)
        let restoredAgain = try await change(recancelled, to: .ordered, service: service)
        #expect(
            restoredAgain.record.supplierSnapshot == nil
                && restoredAgain.record.orderReference == "PO-1")
        let reset = try await change(restoredAgain, to: .needed, service: service)
        let firstAfterReset = try await change(reset, to: .ordered, service: service)
        #expect(
            firstAfterReset.record.supplierSnapshot
                == reset.selectedLink.map(PartSupplierSnapshot.init))
        draft.links[0] = PartLinkDraft(url: "https://example.org/never-ordered")
        draft.selectedLinkID = draft.links[0].id
        let other = try await service.save(draft, for: job.id, editing: nil)
        let cancelledBeforeOrder = try await change(other, to: .cancelled, service: service)
        let firstOrder = try await change(cancelledBeforeOrder, to: .ordered, service: service)
        #expect(
            firstOrder.record.supplierSnapshot == other.selectedLink.map(PartSupplierSnapshot.init))
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
        #expect(
            try await coordinator.read(ActivityQueries.fetchAll).last?.nextValue
                == .part(PartProcurementValue(part: arrived.record)))
        try await coordinator.close()
    }

    @Test(arguments: PartStatus.allCases, [JobStage.completed, .cancelled])
    func closurePreservesProcurementAndTasksAndRejectsStaleSaves(
        status: PartStatus, stage: JobStage
    ) async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = clock
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { clock }))
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        let task = try await JobTaskService(coordinator: coordinator).save(
            JobTaskFixture.draft(.waiting), for: job.id, editing: nil)
        let needed = try await service.save(PartFixture.draft(), for: job.id, editing: nil)
        let part = try await change(needed, to: status, service: service)
        var close = JobTransitionDraft(stage: stage)
        close.outcome = "Bench inspection complete"
        close.cancellationReason = "Owner declined work"
        close.unfinishedTasksReason = "Owner will finish the work"
        let jobs = JobService(coordinator: coordinator)
        if status.isUnresolved {
            await #expect(throws: JobValidationError.self) {
                try await jobs.transition(job.id, using: close)
            }
            close.unfinishedPartsReason = "Owner will source the lot"
        }
        let closed = try await jobs.transition(job.id, using: close)
        #expect(closed.unfinishedPartsReason == JobDraft.optional(close.unfinishedPartsReason))
        #expect(try await coordinator.read(PartQueries.fetchAll) == [part])
        #expect(try await coordinator.read(JobTaskQueries.fetchAll) == [task])
        var stale = PartDraft(part: part)
        stale.status = .installed
        stale.confirmsOnHand = true
        stale.statusReason = "Stale correction"
        await #expect(throws: JobError.closedJob) {
            try await service.save(stale, for: job.id, editing: part.id)
        }
        await #expect(throws: JobError.closedJob) {
            try await service.save(PartFixture.draft(), for: job.id, editing: nil)
        }
        #expect(try await coordinator.read(PartQueries.fetchAll) == [part])
        try await coordinator.close()
    }

    @Test
    func forwardMigrationPreservesSupplierDataHistoryOrderCoverAndOriginals() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let clock = clock
        let coordinator = LibraryCoordinator(
            root: fixture.root, dependencies: LibraryDependencies(now: { clock }))
        let before = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let photoService = PhotoService(coordinator: coordinator)
        let source = try fixture.source(type: .png)
        let bytes = try Data(contentsOf: source)
        let photo = try await photoService.importFiles([source], for: .job(job.id))[0].outcome.get()
        let watch = try await photoService.setCover(photo.id, for: job.watchID)
        let taskService = JobTaskService(coordinator: coordinator)
        _ = try await taskService.save(JobTaskFixture.draft(.done), for: job.id, editing: nil)
        let second = try await taskService.save(
            JobTaskFixture.draft(.waiting), for: job.id, editing: nil)
        let tasks = try await taskService.move(second.id, for: job.id, to: .up)
        var draft = PartFixture.draft()
        var link = PartLinkDraft(url: "https://example.org/part")
        link.supplierName = "Supplier Å時計"
        link.price = "0012.3400"
        link.currency = "DKK"
        draft.links = [link]
        draft.selectedLinkID = link.id
        let part = try await PartService(coordinator: coordinator).save(
            draft, for: job.id, editing: nil)
        let events = try await coordinator.read(ActivityQueries.fetchAll)
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
        #expect(try await reopened.read(JobTaskQueries.fetchAll) == tasks)
        #expect(try await reopened.read(ActivityQueries.fetchAll) == events)
        #expect(try await reopened.read(WatchQueries.fetchAll) == [watch])
        #expect(try await reopened.read(PhotoQueries.fetchAll) == [photo])
        #expect(try Data(contentsOf: await reopened.originalURL(for: photo.asset.id)) == bytes)
        let ordered = try await change(
            part, to: .ordered, service: PartService(coordinator: reopened))
        #expect(ordered.record.supplierSnapshot == part.selectedLink.map(PartSupplierSnapshot.init))
        #expect(
            try await reopened.read(ActivityQueries.fetchAll).last?.ordering
                == (events.last?.ordering ?? 0) + 1)
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
        let events = try await installationLibrary.read(ActivityQueries.fetchAll)
        #expect(events.last?.priorValue == .part(PartProcurementValue(part: installed.record)))
        #expect(events.map(\.occurredAt) == [firstDate, arrivalDate, installDate, installDate])
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
