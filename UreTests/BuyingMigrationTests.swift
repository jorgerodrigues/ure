import CryptoKit
import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct BuyingMigrationTests {
    @Test
    func upgradeTurnsEverySavedLinkIntoAnOptionWithoutAPrice() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        try LegacyBuyingFixture.create(at: fixture.root)
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()

        let stored = try await coordinator.read { db in
            (
                options: try PartOption.fetchAll(
                    db, sql: "SELECT * FROM partOption ORDER BY id"),
                parts: try PartRecord.fetchAll(db, sql: "SELECT * FROM part ORDER BY id"),
                tables: try String.fetchAll(
                    db, sql: "SELECT name FROM sqlite_schema WHERE type = 'table'"),
                money: try MoneyQueries.settings(db),
                integrity: try String.fetchOne(db, sql: "PRAGMA integrity_check"),
                foreignKeys: try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count,
                migrations: try String.fetchAll(
                    db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
            )
        }
        #expect(stored.migrations.last == "v27-buying-options")
        #expect(!stored.tables.contains("partLink") && stored.tables.contains("partOption"))
        #expect(stored.integrity == "ok" && stored.foreignKeys == 0)

        // Every saved link is an option with the same ID, part, place, link and times. Its
        // supplier is the link's host without "www.", and it has no price yet.
        #expect(stored.options.count == LegacyBuyingFixture.links.count)
        for option in stored.options {
            let old = try #require(
                LegacyBuyingFixture.links.first { $0.id == option.id.uuidString })
            #expect(option.partID.uuidString == old.partID && option.url == old.url)
            #expect(option.position == old.position)
            #expect(option.supplier == old.expectedSupplier, "\(old.url)")
            #expect(option.price == nil && option.shipping == nil && option.currency == nil)
            #expect(option.note.isEmpty)
            #expect(option.createdAt.timeIntervalSince1970 == 30)
            #expect(option.updatedAt.timeIntervalSince1970 == 31)
        }

        // Each part keeps every value and its edit time, and nothing is bought yet.
        #expect(stored.parts.map(\.id.uuidString) == LegacyBuyingFixture.parts.map(\.id).sorted())
        for part in stored.parts {
            let old = try #require(LegacyBuyingFixture.parts.first { $0.id == part.id.uuidString })
            #expect(part.name == old.name && part.stage.rawValue == old.stage)
            #expect(part.notes == old.notes && part.purchase == nil)
            #expect(part.updatedAt.timeIntervalSince1970 == 21)
        }
        // No home currency is chosen, so it comes from the Mac's region, and no rate is set.
        #expect(stored.money == MoneySettings())

        // The options take prices, and the part can be marked bought.
        let service = PartService(coordinator: coordinator, region: "EUR")
        let first = try #require(stored.options.first)
        _ = try await service.updateOption(first.id, .currency("GBP"))
        let priced = try await service.updateOption(first.id, .price(Decimal(string: "12.9")))
            .after
        #expect(priced.price == Decimal(string: "12.9") && priced.currency == "GBP")
        try await coordinator.close()
    }

    @Test
    func backupMadeBeforeBuyingOptionsRestoresEveryLink() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        _ = try await WatchService(coordinator: coordinator).create(named: "Replaced by restore")
        let package = fixture.directory.appending(path: "before-buying.watchbackup")
        try LegacyBuyingFixture.package(at: package)
        let staged = try await coordinator.stageRestore(from: package)
        #expect(staged.summary.appliedMigrations == ["v27-buying-options"])
        #expect(staged.summary.counts["partOption"] == LegacyBuyingFixture.links.count)
        #expect(staged.summary.counts["partLink"] == nil)
        let result = try await coordinator.activateRestore(staged)
        #expect(result.outcome == .restored)
        let restored = result.coordinator
        let library = try await restored.read(PartQueries.library)
        #expect(
            Set(library.options.values.flatMap { $0 }.map(\.url))
                == Set(LegacyBuyingFixture.links.map(\.url)))
        #expect(Set(library.parts.map(\.id.uuidString)) == Set(LegacyBuyingFixture.parts.map(\.id)))
        try await restored.close()
    }

    // Every test that takes a library back to an older schema starts with this reversal, so it
    // must leave exactly the schema before v27.
    @Test
    func theReversalLeavesTheSchemaBeforeBuyingOptions() async throws {
        let current = try DatabaseQueue()
        try LibrarySchema.migrator.migrate(current)
        try await current.write { db in try BuyingMigrationFixture.restoreLinks(in: db) }
        let before = try DatabaseQueue()
        try LibrarySchema.migrator.migrate(before, upTo: "v26-parts")
        let schema = """
            SELECT type || char(10) || name || char(10) || tbl_name || char(10) || sql
            FROM sqlite_schema WHERE sql IS NOT NULL
            ORDER BY type, name
            """
        let reversed = try await current.read { try String.fetchAll($0, sql: schema) }
        let expected = try await before.read { try String.fetchAll($0, sql: schema) }
        #expect(reversed == expected)
        #expect(
            try await current.read(LibrarySchema.migrator.appliedMigrations)
                == (try await before.read(LibrarySchema.migrator.appliedMigrations)))
    }

    @Test
    func theDatabaseRefusesMoneyAsAFloatingPointNumber() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let part = try await PartService(coordinator: coordinator).add(named: "Crown", to: job.id)
        let option = try await PartService(coordinator: coordinator).addOption(
            try #require(URL(string: "https://www.cousinsuk.com/crowns")), to: part.id)
        #expect(option.supplier == "cousinsuk.com")
        // A price without a currency, a number that is not plain decimal text, a rate of 0
        // and a purchase on a part to buy are all refused.
        for sql in [
            "UPDATE partOption SET price = '12.9'",
            "UPDATE partOption SET price = '1e3', currency = 'GBP'",
            "UPDATE partOption SET price = '-1', currency = 'GBP'",
            "UPDATE partOption SET price = '12.9', currency = 'gbp'",
            "UPDATE partOption SET price = x'3132', currency = 'GBP'",
            """
            UPDATE part SET paid = '21.4', paidCurrency = 'EUR', boughtPrice = '12.9',
                boughtCurrency = 'GBP'
            """,
            """
            INSERT INTO currencyRate (homeCurrency, currency, rate, updatedAt)
            VALUES ('EUR', 'GBP', '0', 1)
            """,
            """
            INSERT INTO currencyRate (homeCurrency, currency, rate, updatedAt)
            VALUES ('EUR', 'EUR', '1', 1)
            """,
        ] {
            await #expect(throws: DatabaseError.self, "\(sql)") {
                try await coordinator.mutate { db, _, _ in try db.execute(sql: sql) }
            }
        }
        // An exact decimal stays text, digit for digit.
        try await coordinator.mutate { db, _, _ in
            try db.execute(
                sql: "UPDATE partOption SET price = '0.1', shipping = '0.2', currency = 'EUR'")
        }
        let stored = try await coordinator.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT typeof(price) || ' ' || price || ' ' || shipping FROM partOption")
        }
        #expect(stored == ["text 0.1 0.2"])
        let total = try #require(
            try await coordinator.read { try PartQueries.options(of: part.id, in: $0) }.first?.total
        )
        #expect(total == Money(Decimal(string: "0.3") ?? 0, "EUR"))
        try await coordinator.close()
    }
}

// Puts a current library back to the schema before v27, where a part keeps saved links that
// hold only a URL. The part and link tables are made again from the definitions a library at
// v26 has, so the schema matches it exactly, and v27 runs again on the next open. What was bought,
// the home currency and the rates go. Each option goes back as the link it holds.
nonisolated enum BuyingMigrationFixture {
    static func restoreLinks(in db: Database) throws {
        let reference = try DatabaseQueue()
        try LibrarySchema.migrator.migrate(reference, upTo: "v26-parts")
        let definitions = try reference.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT sql FROM sqlite_schema
                    WHERE tbl_name IN ('part', 'partLink') AND sql IS NOT NULL
                    ORDER BY CASE tbl_name WHEN 'part' THEN 0 ELSE 1 END, type DESC, name
                    """)
        }
        let columns = try reference.read { db in try db.columns(in: "part").map(\.name) }
        try reference.close()
        try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
        try db.execute(sql: "CREATE TEMP TABLE part_copy AS SELECT * FROM part")
        try db.execute(sql: "CREATE TEMP TABLE partOption_copy AS SELECT * FROM partOption")
        try db.drop(table: "partOption")
        try db.drop(table: "part")
        try db.drop(table: "currencyRate")
        try db.drop(table: "librarySetting")
        for definition in definitions { try db.execute(sql: definition) }
        let list = columns.joined(separator: ", ")
        try db.execute(sql: "INSERT INTO part (\(list)) SELECT \(list) FROM part_copy")
        try db.execute(
            sql: """
                INSERT INTO partLink (id, partID, position, url, createdAt, updatedAt)
                SELECT id, partID, position, url, createdAt, updatedAt FROM partOption_copy
                """)
        try db.execute(sql: "DROP TABLE part_copy")
        try db.execute(sql: "DROP TABLE partOption_copy")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v27-buying-options'")
    }
}

// A library and a backup package made by the schema before v27. Its parts are on a job and in
// the drawer, and they have saved links: listings with and without "www.", a link without a
// path, and a part with two links.
nonisolated enum LegacyBuyingFixture {
    private static let lastMigration = "v26-parts"

    struct Part {
        let id: String
        let jobID: String?
        let name: String
        let stage: String
        var orderedAt: Double? = nil
        var inHandAt: Double? = nil
        var notes = ""
    }

    struct Link {
        let id: String
        let partID: String
        let position: Int
        let url: String
        let expectedSupplier: String
    }

    static let watchID = "00000000-0000-4000-8000-000000002701"
    static let jobID = "00000000-0000-4000-8000-000000002711"

    static let parts = [
        Part(
            id: "00000000-0000-4000-8000-000000002721", jobID: jobID, name: "Mainspring",
            stage: "Needed", notes: "GR number from the service guide"),
        Part(
            id: "00000000-0000-4000-8000-000000002722", jobID: jobID, name: "Crystal gasket",
            stage: "Ordered", orderedAt: 1_790_000_000),
        Part(
            id: "00000000-0000-4000-8000-000000002723", jobID: nil, name: "Crystal, 29.5 mm",
            stage: "In hand", inHandAt: 1_790_100_000),
    ]

    static let links = [
        Link(
            id: "00000000-0000-4000-8000-000000002731", partID: parts[0].id, position: 0,
            url: "https://www.cousinsuk.com/product/gr3807x", expectedSupplier: "cousinsuk.com"),
        Link(
            id: "00000000-0000-4000-8000-000000002732", partID: parts[0].id, position: 1,
            url: "https://ebay.co.uk/itm/552-mainspring?x=1", expectedSupplier: "ebay.co.uk"),
        Link(
            id: "00000000-0000-4000-8000-000000002733", partID: parts[1].id, position: 0,
            url: "http://esslinger.com", expectedSupplier: "esslinger.com"),
        Link(
            id: "00000000-0000-4000-8000-000000002734", partID: parts[2].id, position: 0,
            url: "https://www.sternkreuz.de/en/crystals", expectedSupplier: "sternkreuz.de"),
    ]

    static func create(at root: URL) throws {
        let generationID = UUID()
        let generation = LibraryFiles.generation(generationID, in: root)
        try FileManager.default.createDirectory(
            at: LibraryFiles.originals(in: generation), withIntermediateDirectories: true)
        _ = try database(in: generation)
        try LibraryFiles.write(
            ActiveLibrary(
                formatVersion: LibraryManifest.currentVersion, generationID: generationID),
            to: root.appending(path: "active-library.json"))
    }

    static func package(at package: URL) throws {
        try FileManager.default.createDirectory(
            at: LibraryFiles.originals(in: package), withIntermediateDirectories: true)
        let manifest = try database(in: package)
        let reader = try DatabaseQueue(path: LibraryFiles.database(in: package).path)
        let counts = try reader.read(BackupQueries.counts)
        try reader.close()
        let migrations = LibrarySchema.migrator.migrations
        let lastIndex = try #require(migrations.firstIndex(of: lastMigration))
        try LibraryFiles.write(
            BackupManifest(
                formatVersion: BackupManifest.currentVersion,
                exportedAt: Date(timeIntervalSince1970: 1_793_000_000),
                libraryID: manifest.libraryID, applicationVersion: "before W041",
                migrations: Array(migrations[...lastIndex]), counts: counts,
                files: try ["library.sqlite", "manifest.json"].map {
                    try fingerprint(package.appending(path: $0), path: $0)
                }),
            to: package.appending(path: "backup.json"))
    }

    private static func database(in directory: URL) throws -> LibraryManifest {
        let manifest = LibraryManifest(
            formatVersion: LibraryManifest.currentVersion, libraryID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.25))
        try LibraryFiles.write(manifest, to: directory.appending(path: "manifest.json"))
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let database = try DatabaseQueue(
            path: LibraryFiles.database(in: directory).path, configuration: configuration)
        try LibrarySchema.migrator.migrate(database, upTo: lastMigration)
        try database.write { db in
            try db.execute(
                sql: "INSERT INTO libraryMetadata (id, createdAt) VALUES (?, ?)",
                arguments: [
                    manifest.libraryID.uuidString, manifest.createdAt.timeIntervalSince1970,
                ])
            try db.execute(
                sql: "INSERT INTO watch (id, name, createdAt, updatedAt) VALUES (?, ?, 1, 2)",
                arguments: [watchID, "Grandfather’s Seamaster"])
            try db.execute(
                sql: """
                    INSERT INTO job (id, watchID, title, stage, createdAt, updatedAt)
                    VALUES (?, ?, 'Full service', 'In progress', 10, 11)
                    """, arguments: [jobID, watchID])
            for (position, part) in parts.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO part (id, jobID, position, name, stage, orderedAt, inHandAt,
                            notes, createdAt, updatedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 20, 21)
                        """,
                    arguments: [
                        part.id, part.jobID, part.jobID == nil ? 0 : position, part.name,
                        part.stage, part.orderedAt, part.inHandAt, part.notes,
                    ])
            }
            for link in links {
                try db.execute(
                    sql: """
                        INSERT INTO partLink (id, partID, position, url, createdAt, updatedAt)
                        VALUES (?, ?, ?, ?, 30, 31)
                        """, arguments: [link.id, link.partID, link.position, link.url])
            }
            try SearchKey.backfill("job", fields: ["title", "notes"], in: db)
            try SearchKey.backfill("part", fields: ["name", "description", "notes"], in: db)
        }
        try database.close()
        return manifest
    }

    private static func fingerprint(_ file: URL, path: String) throws -> SnapshotFile {
        let bytes = try Data(contentsOf: file)
        return SnapshotFile(
            path: path, byteCount: Int64(bytes.count),
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
}
