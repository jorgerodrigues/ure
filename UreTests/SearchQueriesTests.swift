import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct SearchQueriesTests {
    @Test
    func allDefinedFieldsKeepUnicodeAndLiteralIdentifiersAfterRestart() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = LibraryCoordinator(
            root: fixture.root, dependencies: LibraryDependencies(now: { date }))
        _ = try await coordinator.open()
        var caliberDraft = CaliberDraft()
        caliberDraft.designation = "ÉТА 0012/Å"
        let caliber = try await CaliberService(coordinator: coordinator).save(
            caliberDraft, editing: nil)
        var watchDraft = WatchDraft()
        watchDraft.name = "Straße 時計"
        watchDraft.brand = "ΜΆΡΚΑ"
        watchDraft.model = "МОДЕЛЬ"
        watchDraft.caseReference = "0012–Å/04"
        watchDraft.serial = "000042.7-A"
        watchDraft.caliberID = caliber.id
        let watch = try await WatchService(coordinator: coordinator).save(watchDraft, editing: nil)
        var jobDraft = JobDraft()
        jobDraft.title = "Réparation"
        let job = try await JobService(coordinator: coordinator).save(
            jobDraft, for: watch.id, editing: nil)
        var noteDraft = NoteDraft(occurredAt: date)
        noteDraft.title = "Finding"
        noteDraft.body =
            "Café e\u{301} 100%_ [brackets] 'quotes' \"double\" \\path '; DROP TABLE watch;--"
        let note = try await NoteService(coordinator: coordinator).save(
            noteDraft, for: .job(job.id), editing: nil)
        var partDraft = PartFixture.draft()
        partDraft.description = "Ressort"
        partDraft.manufacturerReference = "0007-A/02"
        partDraft.links = [
            PartLinkDraft(url: "https://example.org/part"),
            PartLinkDraft(url: "https://example.org/other"),
        ]
        partDraft.links[0].supplierStockCode = "0012–Å/stock"
        partDraft.links[1].supplierStockCode = "0012–Å/stock"
        let part = try await PartService(coordinator: coordinator).save(
            partDraft, for: job.id, editing: nil)
        var referenceDraft = ReferenceFixture.draft
        referenceDraft.title = "Sheet link"
        let reference = try await ReferenceService(coordinator: coordinator).save(
            referenceDraft, for: .caliber(caliber.id), editing: nil)
        let source = try fixture.source(type: .png)
        let photo = try #require(
            await PhotoService(coordinator: coordinator).importFiles(
                [source], for: .watch(watch.id)
            ).first
        ).outcome.get()
        var photoDraft = PhotoDraft(item: photo.item)
        photoDraft.title = "Dial photo"
        photoDraft.caption = "LÉGENDE"
        _ = try await PhotoService(coordinator: coordinator).save(
            photoDraft, for: .watch(watch.id), editing: photo.id)
        let pdf = try DocumentFixture.source(in: fixture)
        let document = try #require(
            await DocumentService(coordinator: coordinator).importFiles([pdf], for: .job(job.id))
                .first
        ).outcome.get()
        var documentDraft = DocumentDraft(item: document.item)
        documentDraft.title = "Technical PDF"
        _ = try await DocumentService(coordinator: coordinator).save(
            documentDraft, for: .job(job.id), editing: document.id)
        let cases: [(String, UUID)] = [
            ("STRASSE", watch.id), ("時計", watch.id), ("μάρκα", watch.id), ("модель", watch.id),
            ("0012–å/04", watch.id), ("000042.7-a", watch.id), ("éта 0012/å", caliber.id),
            ("RÉPARATION", job.id), ("finding", note.id), ("cafe\u{301}", note.id),
            ("100%_", note.id), ("[brackets]", note.id), ("'quotes'", note.id),
            ("\"double\"", note.id), ("\\path", note.id), ("'; DROP TABLE watch;--", note.id),
            ("ressort", part.id), ("0007-A/02", part.id), ("0012–å/stock", part.id),
            ("sheet link", reference.id), ("dial photo", photo.id), ("légende", photo.id),
            ("technical pdf", document.id),
        ]
        for (query, id) in cases {
            let results = try await coordinator.read { try SearchQueries.fetch(query, in: $0) }
            #expect(results.map(\.recordID) == [id])
            #expect(results.first?.context.isEmpty == false)
        }
        for query in ["missing", "%", "_", "   "] {
            let results = try await coordinator.read { try SearchQueries.fetch(query, in: $0) }
            if query == "%" || query == "_" {
                #expect(results.map(\.recordID) == [note.id])
            } else {
                #expect(results.isEmpty)
            }
        }
        #expect(try await coordinator.read(WatchQueries.fetchAll).count == 1)
        let before = try await coordinator.read { try SearchQueries.fetch("0012", in: $0) }
        let photoBytes = try Data(contentsOf: source)
        let pdfBytes = try Data(contentsOf: pdf)
        try await coordinator.mutate { db, _, _ in try SearchMigrationFixture.removeSearch(in: db) }
        try await coordinator.close()
        let restarted = LibraryCoordinator(root: fixture.root)
        _ = try await restarted.open()
        #expect(try await restarted.read { try SearchQueries.fetch("0012", in: $0) } == before)
        for (query, id) in cases {
            #expect(
                try await restarted.read { try SearchQueries.fetch(query, in: $0) }.map(\.recordID)
                    == [id])
        }
        #expect(
            try Data(contentsOf: try await restarted.originalURL(for: photo.asset.id)) == photoBytes
        )
        #expect(
            try Data(contentsOf: try await restarted.originalURL(for: document.asset.id))
                == pdfBytes)
        var editedWatch = WatchDraft(watch: watch)
        editedWatch.name = "Corrected watch"
        editedWatch.serial = "0099-new"
        _ = try await WatchService(coordinator: restarted).save(editedWatch, editing: watch.id)
        var editedCaliber = CaliberDraft(caliber: caliber)
        editedCaliber.designation = "Corrected caliber"
        _ = try await CaliberService(coordinator: restarted).save(
            editedCaliber, editing: caliber.id)
        var editedJob = JobDraft(job: job)
        editedJob.title = "Corrected repair"
        _ = try await JobService(coordinator: restarted).save(
            editedJob, for: watch.id, editing: job.id)
        referenceDraft.title = "Corrected link"
        _ = try await ReferenceService(coordinator: restarted).save(
            referenceDraft, for: .caliber(caliber.id), editing: reference.id)
        photoDraft.caption = "Corrected caption"
        _ = try await PhotoService(coordinator: restarted).save(
            photoDraft, for: .watch(watch.id), editing: photo.id)
        documentDraft.title = "Corrected PDF"
        _ = try await DocumentService(coordinator: restarted).save(
            documentDraft, for: .job(job.id), editing: document.id)
        for query in [
            "STRASSE", "000042.7-a", "éта 0012/å", "RÉPARATION", "sheet link", "légende",
            "technical pdf",
        ] {
            #expect(try await restarted.read { try SearchQueries.fetch(query, in: $0) }.isEmpty)
        }
        for (query, id) in [
            ("corrected watch", watch.id), ("0099-new", watch.id),
            ("corrected caliber", caliber.id), ("corrected repair", job.id),
            ("corrected link", reference.id), ("corrected caption", photo.id),
            ("corrected pdf", document.id),
        ] {
            #expect(
                try await restarted.read { try SearchQueries.fetch(query, in: $0) }.map(\.recordID)
                    == [id])
        }
        try await restarted.mutate { db, _, _ in
            try db.execute(
                sql: "UPDATE caliber SET archivedAt = 1 WHERE id = ?",
                arguments: [caliber.id.uuidString])
        }
        #expect(
            try await restarted.read { try SearchQueries.fetch("corrected caliber", in: $0) }
                .isEmpty)
        #expect(
            try await restarted.read { try SearchQueries.fetch("corrected link", in: $0) }.isEmpty)
        #expect(
            try await restarted.read { try SearchQueries.fetch("corrected watch", in: $0) }.count
                == 1)
        #expect(
            try await restarted.read {
                try SearchQueries.fetch("corrected link", includeArchived: true, in: $0)
            }.first?.isArchived == true)
        try await restarted.close()
    }

    @Test
    func editsRemovalRollbackAndArchiveAncestorsRefreshSearch() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { date }))
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = NoteService(coordinator: coordinator)
        var draft = NoteDraft(occurredAt: date)
        draft.title = "Duplicate"
        draft.body = "original"
        let note = try await service.save(draft, for: .job(job.id), editing: nil)
        let duplicate = try await service.save(draft, for: .watch(job.watchID), editing: nil)
        #expect(
            Set(
                try await coordinator.read { try SearchQueries.fetch("duplicate", in: $0) }.map(
                    \.recordID)) == [note.id, duplicate.id])
        draft.body = "corrected"
        _ = try await service.save(draft, for: .job(job.id), editing: note.id)
        #expect(
            try await coordinator.read { try SearchQueries.fetch("original", in: $0) }.map(
                \.recordID) == [duplicate.id])
        #expect(
            try await coordinator.read { try SearchQueries.fetch("corrected", in: $0) }.map(
                \.recordID) == [note.id])
        await #expect(throws: SearchFixtureFailure.self) {
            try await coordinator.mutate { db, _, _ in
                try db.execute(
                    sql: "UPDATE note SET body = 'rolled back' WHERE id = ?",
                    arguments: [note.id.uuidString])
                try SearchKey.refresh(note.id, table: .note, in: db)
                throw SearchFixtureFailure()
            }
        }
        #expect(
            try await coordinator.read { try SearchQueries.fetch("rolled back", in: $0) }.isEmpty)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: "UPDATE job SET archivedAt = ? WHERE id = ?",
                arguments: [date.timeIntervalSince1970, job.id.uuidString])
        }
        #expect(try await coordinator.read { try SearchQueries.fetch("corrected", in: $0) }.isEmpty)
        #expect(
            try await coordinator.read {
                try SearchQueries.fetch("corrected", includeArchived: true, in: $0)
            }.first?.isArchived == true)
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: "UPDATE watch SET archivedAt = ? WHERE id = ?",
                arguments: [date.timeIntervalSince1970, job.watchID.uuidString])
        }
        #expect(try await coordinator.read { try SearchQueries.fetch("duplicate", in: $0) }.isEmpty)
        #expect(
            try await coordinator.read {
                try SearchQueries.fetch("duplicate", includeArchived: true, in: $0)
            }.count == 2)
        try await coordinator.mutate { db, _, _ in
            try db.execute(sql: "DELETE FROM note WHERE id = ?", arguments: [note.id.uuidString])
        }
        #expect(
            try await coordinator.read {
                try SearchQueries.fetch("corrected", includeArchived: true, in: $0)
            }.isEmpty)
        try await coordinator.close()
    }

    @Test
    func duplicateCaliberDesignationsUseTheirVariantsInResultsAndOwnedContext() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { date }))
        _ = try await coordinator.open()
        var labels: [UUID: String] = [:]
        for variant in ["Elaboré", "Top"] {
            var draft = CaliberDraft()
            draft.designation = "ETA 2824-2"
            draft.variant = variant
            let caliber = try await CaliberService(coordinator: coordinator).save(
                draft, editing: nil)
            labels[caliber.id] = caliber.label
            var noteDraft = NoteDraft(occurredAt: date)
            noteDraft.title = "Service interval"
            _ = try await NoteService(coordinator: coordinator).save(
                noteDraft, for: .caliber(caliber.id), editing: nil)
            var linkDraft = ReferenceFixture.draft
            linkDraft.title = "Service interval"
            _ = try await ReferenceService(coordinator: coordinator).save(
                linkDraft, for: .caliber(caliber.id), editing: nil)
        }
        let calibers = try await coordinator.read { try SearchQueries.fetch("2824", in: $0) }
        #expect(calibers.count == 2 && Set(calibers.map(\.title)) == Set(labels.values))
        #expect(calibers.allSatisfy { $0.caliberLabel == labels[$0.recordID] })
        let owned = try await coordinator.read {
            try SearchQueries.fetch("Service interval", in: $0)
        }
        #expect(owned.count == 4)
        for result in owned {
            let caliberID = try #require(result.caliberID)
            #expect(result.caliberLabel == labels[caliberID])
            #expect(result.context == "Caliber · \(labels[caliberID] ?? "missing")")
        }
        try await coordinator.close()
    }

    @Test
    func orderSnapshotStockCodeStaysSearchableAfterSupplierOptionRemoval() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(coordinator: coordinator)
        var draft = PartFixture.draft()
        draft.links = [PartLinkDraft(url: "https://example.org/supplier")]
        draft.links[0].supplierStockCode = "0009-Å/ordered"
        draft.selectedLinkID = draft.links[0].id
        let needed = try await service.save(draft, for: job.id, editing: nil)
        var orderDraft = PartDraft(part: needed)
        orderDraft.status = .ordered
        let ordered = try await service.save(orderDraft, for: job.id, editing: needed.id)
        var edit = PartDraft(part: ordered)
        edit.links = []
        edit.selectedLinkID = nil
        let saved = try await service.save(edit, for: job.id, editing: ordered.id)
        #expect(saved.record.supplierSnapshot == ordered.record.supplierSnapshot)
        #expect(
            try await coordinator.read { try SearchQueries.fetch("0009-å/ordered", in: $0) }.map(
                \.recordID) == [ordered.id])
        try await coordinator.close()
    }

    @Test
    func migrationBackfillsPartsAndSupplierCodesWithoutChangingSavedRecords() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        var draft = PartFixture.draft()
        draft.manufacturerReference = "0012-Å"
        draft.links = [PartLinkDraft(url: "https://example.org/part")]
        draft.links[0].supplierStockCode = "0009/É"
        let part = try await PartService(coordinator: coordinator).save(
            draft, for: job.id, editing: nil)
        try await coordinator.mutate { db, _, _ in try SearchMigrationFixture.removeSearch(in: db) }
        try await coordinator.close()
        let upgraded = fixture.coordinator()
        _ = try await upgraded.open()
        #expect(
            try await upgraded.read { try SearchQueries.fetch("0012-å", in: $0) }.map(\.recordID)
                == [part.id])
        #expect(
            try await upgraded.read { try SearchQueries.fetch("0009/é", in: $0) }.map(\.recordID)
                == [part.id])
        #expect(try await upgraded.read(PartQueries.fetchAll) == [part])
        #expect(try await upgraded.read(JobQueries.fetchAll) == [job])
        try await upgraded.close()
    }
}

nonisolated struct SearchFixtureFailure: Error {}

nonisolated enum SearchMigrationFixture {
    static func removeSearch(in db: Database) throws {
        for table in SearchKey.Table.allCases {
            try db.execute(sql: "DROP INDEX \(table.rawValue)_searchKey")
            try db.execute(sql: "ALTER TABLE \(table.rawValue) DROP COLUMN searchKey")
        }
        for table in ["watch", "caliber", "job"] {
            try db.execute(sql: "DROP INDEX \(table)_archivedAt")
            try db.execute(sql: "ALTER TABLE \(table) DROP COLUMN archivedAt")
        }
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v17-search'")
    }
}
