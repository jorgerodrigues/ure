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
        let caliber = try await CaliberService(coordinator: coordinator).create(
            named: "ÉТА 0012/Å")
        let watches = WatchService(coordinator: coordinator)
        var watch = try await watches.make("Straße 時計", brand: "ΜΆΡΚΑ", caliberID: caliber.id)
        for fact in [
            WatchFact.model("МОДЕЛЬ"), .reference("0012–Å/04"), .serial("000042.7-A"),
            .owner("Ödön Ünal"), .contact("ODON@EXAMPLE.ORG"),
        ] {
            watch = try await watches.update(watch.id, fact)
        }
        let job = try await JobService(coordinator: coordinator).start(
            for: watch.id, title: "Réparation")
        try await RecordNotesService(coordinator: coordinator).save(
            "Finding\nCafé e\u{301} 100%_ [brackets] 'quotes' \"double\" \\path '; DROP TABLE watch;--",
            for: .job(job.id))
        let parts = PartService(coordinator: coordinator)
        let part = try await parts.add(named: "Ressort", to: job.id)
        _ = try await parts.update(part.id, .description("0007-A/02"))
        let reference = try await MaterialFixture.link(
            titled: "Sheet link", for: .caliber(caliber.id), in: coordinator)
        let source = try fixture.source(type: .png)
        let photo = try await MaterialFixture.file(
            source, titled: "Dial photo · LÉGENDE", for: .watch(watch.id), in: coordinator)
        let pdf = try DocumentFixture.source(in: fixture)
        let document = try await MaterialFixture.file(
            pdf, titled: "Technical PDF", for: .job(job.id), in: coordinator)
        let cases: [(String, UUID)] = [
            ("STRASSE", watch.id), ("時計", watch.id), ("μάρκα", watch.id), ("модель", watch.id),
            ("0012–å/04", watch.id), ("000042.7-a", watch.id), ("ödön ünal", watch.id),
            ("odon@example", watch.id), ("éта 0012/å", caliber.id),
            ("RÉPARATION", job.id), ("finding", job.id), ("cafe\u{301}", job.id),
            ("100%_", job.id), ("[brackets]", job.id), ("'quotes'", job.id),
            ("\"double\"", job.id), ("\\path", job.id), ("'; DROP TABLE watch;--", job.id),
            ("ressort", part.id), ("0007-A/02", part.id),
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
                #expect(results.map(\.recordID) == [job.id])
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
            try Data(contentsOf: try await restarted.originalURL(for: try #require(photo.asset).id))
                == photoBytes)
        #expect(
            try Data(
                contentsOf: try await restarted.originalURL(for: try #require(document.asset).id))
                == pdfBytes)
        let restartedWatches = WatchService(coordinator: restarted)
        _ = try await restartedWatches.update(watch.id, .name("Corrected watch"))
        _ = try await restartedWatches.update(watch.id, .serial("0099-new"))
        _ = try await CaliberService(coordinator: restarted).update(
            caliber.id, .name("Corrected caliber"))
        _ = try await JobService(coordinator: restarted).update(
            job.id, .title("Corrected repair"))
        let material = MaterialService(coordinator: restarted)
        try await material.rename(reference.id, to: "Corrected link", for: .caliber(caliber.id))
        try await material.rename(photo.id, to: "Corrected caption", for: .watch(watch.id))
        try await material.rename(document.id, to: "Corrected PDF", for: .job(job.id))
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
        // An archived caliber and its material stay in search and say that they are archived.
        #expect(
            try await restarted.read { try SearchQueries.fetch("corrected caliber", in: $0) }
                .map(\.isArchived) == [true])
        #expect(
            try await restarted.read { try SearchQueries.fetch("corrected link", in: $0) }
                .map(\.isArchived) == [true])
        #expect(
            try await restarted.read { try SearchQueries.fetch("corrected watch", in: $0) }
                .map(\.isArchived) == [false])
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
        let service = RecordNotesService(coordinator: coordinator)
        try await service.save("Duplicate original", for: .job(job.id))
        let watchID = try #require(job.watchID)
        try await service.save("Duplicate original", for: .watch(watchID))
        #expect(
            Set(
                try await coordinator.read { try SearchQueries.fetch("duplicate", in: $0) }.map(
                    \.recordID)) == [job.id, watchID])
        try await service.save("Duplicate corrected", for: .job(job.id))
        #expect(
            try await coordinator.read { try SearchQueries.fetch("original", in: $0) }.map(
                \.recordID) == [watchID])
        #expect(
            try await coordinator.read { try SearchQueries.fetch("corrected", in: $0) }.map(
                \.recordID) == [job.id])
        await #expect(throws: SearchFixtureFailure.self) {
            try await coordinator.mutate { db, _, _ in
                try db.execute(
                    sql: "UPDATE job SET notes = 'rolled back' WHERE id = ?",
                    arguments: [job.id.uuidString])
                try SearchKey.refresh(job.id, table: .job, in: db)
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
        #expect(
            try await coordinator.read { try SearchQueries.fetch("corrected", in: $0) }.map(
                \.isArchived) == [true])
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: "UPDATE watch SET archivedAt = ? WHERE id = ?",
                arguments: [date.timeIntervalSince1970, watchID.uuidString])
        }
        let archived = try await coordinator.read { try SearchQueries.fetch("duplicate", in: $0) }
        #expect(archived.count == 2 && archived.allSatisfy { $0.isArchived })
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: "UPDATE job SET notes = '' WHERE id = ?", arguments: [job.id.uuidString])
            try SearchKey.refresh(job.id, table: .job, in: db)
        }
        #expect(try await coordinator.read { try SearchQueries.fetch("corrected", in: $0) }.isEmpty)
        try await coordinator.close()
    }

    @Test
    func duplicateCaliberNamesUseTheirMakersInResultsAndOwnedContext() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: { date }))
        _ = try await coordinator.open()
        var labels: [UUID: String] = [:]
        let service = CaliberService(coordinator: coordinator)
        for maker in ["ETA", "Sellita"] {
            let created = try await service.create(named: "2824-2")
            let caliber = try await service.update(created.id, .maker(maker))
            labels[caliber.id] = caliber.title
            try await RecordNotesService(coordinator: coordinator).save(
                "Service interval", for: .caliber(caliber.id))
            _ = try await MaterialFixture.link(
                titled: "Service interval", for: .caliber(caliber.id), in: coordinator)
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
    func migrationBackfillsPartsWithoutChangingSavedRecords() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let parts = PartService(coordinator: coordinator)
        let added = try await parts.add(named: "Mainspring", to: job.id)
        let part = try await parts.update(added.id, .description("0012-Å"))
        try await coordinator.mutate { db, _, _ in try SearchMigrationFixture.removeSearch(in: db) }
        try await coordinator.close()
        let upgraded = fixture.coordinator()
        _ = try await upgraded.open()
        #expect(
            try await upgraded.read { try SearchQueries.fetch("0012-å", in: $0) }.map(\.recordID)
                == [part.id])
        #expect(try await upgraded.read(PartQueries.fetchAll) == [part])
        #expect(try await upgraded.read(JobQueries.fetchAll) == [job])
        try await upgraded.close()
    }
}

nonisolated struct SearchFixtureFailure: Error {}

nonisolated enum SearchMigrationFixture {
    static func removeSearch(in db: Database) throws {
        try PartLinkMigrationFixture.restoreSupplierOptions(in: db)
        for table in [
            "watch", "caliber", "job", "note", "libraryItem", "partRequirement", "partLink",
        ] {
            try db.execute(sql: "DROP INDEX \(table)_searchKey")
            try db.execute(sql: "ALTER TABLE \(table) DROP COLUMN searchKey")
        }
        for table in ["watch", "caliber", "job"] {
            try db.execute(sql: "DROP INDEX \(table)_archivedAt")
            try db.execute(sql: "ALTER TABLE \(table) DROP COLUMN archivedAt")
        }
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v17-search'")
    }
}
