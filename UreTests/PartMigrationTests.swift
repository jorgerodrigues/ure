import CryptoKit
import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct PartMigrationTests {
    @Test
    func upgradeTurnsEveryRequirementIntoAPartAndLosesNothingTyped() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        try LegacyPartFixture.create(at: fixture.root)
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()

        let stored = try await coordinator.read { db in
            (
                parts: try PartRecord.fetchAll(db, sql: "SELECT * FROM part ORDER BY createdAt"),
                options: try PartOption.fetchAll(db, sql: "SELECT * FROM partOption ORDER BY id"),
                jobs: try JobRecord.fetchAll(db, sql: "SELECT * FROM job ORDER BY id"),
                jobNotes: try String.fetchAll(db, sql: "SELECT notes FROM job ORDER BY id"),
                tables: try String.fetchAll(
                    db, sql: "SELECT name FROM sqlite_schema WHERE type = 'table'"),
                integrity: try String.fetchOne(db, sql: "PRAGMA integrity_check"),
                foreignKeys: try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count,
                migrations: try String.fetchAll(
                    db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
            )
        }
        #expect(stored.migrations.contains("v26-parts"))
        #expect(!stored.tables.contains("partRequirement") && stored.tables.contains("part"))
        #expect(stored.integrity == "ok" && stored.foreignKeys == 0)

        // Each part that was not cancelled is kept with its ID, job, quantity, state and dates.
        let kept = LegacyPartFixture.parts.filter { $0.status != "Cancelled" }
        #expect(stored.parts.map(\.id.uuidString) == kept.map(\.id))
        for (part, old) in zip(stored.parts, kept) {
            #expect(part.jobID?.uuidString == old.jobID, "\(old.description)")
            #expect(part.name == old.description && part.description == old.reference)
            #expect(part.quantity == old.quantity)
            #expect(part.stage == old.expectedStage, "\(old.description)")
            #expect(part.orderedAt?.timeIntervalSince1970 == old.expectedOrderedAt)
            #expect(part.inHandAt?.timeIntervalSince1970 == old.expectedInHandAt)
            #expect(part.fittedAt?.timeIntervalSince1970 == old.expectedFittedAt)
            #expect(part.position == old.expectedPosition, "\(old.description)")
            #expect(part.notes == old.expectedNotes(), "\(old.description)")
            // The migration does not change when the part was last edited.
            #expect(part.createdAt.timeIntervalSince1970 == old.createdAt)
            #expect(part.updatedAt.timeIntervalSince1970 == old.createdAt + 1)
        }

        // Saved links stay on their parts, as options since v27, and a cancelled part's links
        // are in its job's notes.
        let keptLinks = LegacyPartFixture.links.filter { link in
            kept.contains { $0.id == link.partID }
        }
        #expect(stored.options.map(\.id.uuidString) == keptLinks.map(\.id).sorted())
        for option in stored.options {
            let old = try #require(keptLinks.first { $0.id == option.id.uuidString })
            #expect(option.partID.uuidString == old.partID && option.url == old.url)
            #expect(option.position == old.position)
            #expect(option.createdAt.timeIntervalSince1970 == 30)
        }

        // A cancelled part goes into its job's notes with every value and link, after any notes
        // the job had. No job's edit time changes.
        for (notes, job) in zip(stored.jobNotes, LegacyPartFixture.jobs.sorted { $0.id < $1.id }) {
            #expect(notes == job.expectedNotes(), "\(job.title)")
        }
        #expect(stored.jobs.allSatisfy { $0.updatedAt.timeIntervalSince1970 == 11 })

        // Search finds a part by its name, its description and the values in its notes, and a
        // cancelled part through its job.
        for (query, id) in [
            ("mainspring", LegacyPartFixture.parts[0].id),
            ("gr 3800", LegacyPartFixture.parts[0].id),
            ("po-1182", LegacyPartFixture.parts[1].id),
            ("owner kept the old hands", LegacyPartFixture.jobs[0].id),
        ] {
            let found = try await coordinator.read { try SearchQueries.fetch(query, in: $0) }
            #expect(found.map(\.recordID.uuidString) == [id], "\(query)")
        }

        // The parts still change, and the new state cycle works on them.
        let service = PartService(coordinator: coordinator)
        let ordered = try #require(UUID(uuidString: LegacyPartFixture.parts[1].id))
        #expect(try await service.advance(ordered).part.stage == .inHand)
        try await coordinator.close()
    }

    @Test
    func backupMadeBeforePartsRestoresEveryPart() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        _ = try await WatchService(coordinator: coordinator).create(named: "Replaced by restore")
        let package = fixture.directory.appending(path: "before-parts.watchbackup")
        try LegacyPartFixture.package(at: package)
        let staged = try await coordinator.stageRestore(from: package)
        #expect(staged.summary.appliedMigrations == ["v26-parts", "v27-buying-options"])
        let kept = LegacyPartFixture.parts.filter { $0.status != "Cancelled" }
        #expect(staged.summary.counts["part"] == kept.count)
        #expect(staged.summary.counts["partRequirement"] == nil)
        let result = try await coordinator.activateRestore(staged)
        #expect(result.outcome == .restored)
        let restored = result.coordinator
        let parts = try await restored.read(PartQueries.fetchAll)
        #expect(Set(parts.map(\.id.uuidString)) == Set(kept.map(\.id)))
        for old in kept {
            let part = try #require(parts.first { $0.id.uuidString == old.id })
            #expect(part.stage == old.expectedStage && part.notes == old.expectedNotes())
            #expect(part.jobID?.uuidString == old.jobID && part.quantity == old.quantity)
        }
        let job = try #require(UUID(uuidString: LegacyPartFixture.jobs[0].id))
        #expect(
            try await RecordNotesService(coordinator: restored).text(for: .job(job))
                == LegacyPartFixture.jobs[0].expectedNotes())
        try await restored.close()
    }

    // Every test that takes a library back to an older schema starts with this reversal, so it
    // must leave exactly the schema before v26.
    @Test
    func theReversalLeavesTheSchemaBeforeParts() async throws {
        let current = try DatabaseQueue()
        try LibrarySchema.migrator.migrate(current)
        try await current.write { db in try PartMigrationFixture.restoreRequirements(in: db) }
        let before = try DatabaseQueue()
        try LibrarySchema.migrator.migrate(before, upTo: "v25-jobs-without-watch")
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
    func eachPartWritesOnlyTheValuesThatGo() {
        let plain = LegacyPartFixture.old(status: "Needed")
        #expect(
            PartMigration.partEntry(for: plain, stage: .needed, locale: .current, timeZone: .gmt)
                == nil)
        let blank = LegacyPartFixture.old(
            compatibilityNote: " \n", status: "Ordered", orderReference: "", statusReason: "  ")
        #expect(
            PartMigration.partEntry(for: blank, stage: .ordered, locale: .current, timeZone: .gmt)
                == nil)
        #expect(PartMigration.stage(of: "Arrived") == .inHand)
        #expect(PartMigration.stage(of: "Installed") == .fitted)
        #expect(PartMigration.stage(of: "Cancelled") == nil)
        let cancelled = LegacyPartFixture.old(status: "Cancelled")
        #expect(
            PartMigration.jobEntry(
                for: cancelled, links: [], locale: .current, timeZone: .gmt)
                == "Part · Spring\nCancelled")
    }
}

// Puts a current library back to the schema before v26, where each part is a requirement of one
// job. The tables are made again from the definitions a library at v25 has, so the schema
// matches it exactly, and v26 runs again on the next open. Spares have no job, so they go. The
// rows go back in after the new tables are made, which keeps SQLite's deferred foreign key count
// balanced.
nonisolated enum PartMigrationFixture {
    static func restoreRequirements(in db: Database) throws {
        try BuyingMigrationFixture.restoreLinks(in: db)
        let reference = try DatabaseQueue()
        try LibrarySchema.migrator.migrate(reference, upTo: "v25-jobs-without-watch")
        let definitions = try reference.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT sql FROM sqlite_schema
                    WHERE tbl_name IN ('partRequirement', 'partLink') AND sql IS NOT NULL
                    ORDER BY type DESC, name
                    """)
        }
        try reference.close()
        try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
        try db.execute(
            sql: "CREATE TEMP TABLE part_copy AS SELECT * FROM part WHERE jobID IS NOT NULL")
        try db.execute(
            sql: """
                CREATE TEMP TABLE partLink_copy AS SELECT * FROM partLink
                WHERE partID IN (SELECT id FROM part_copy)
                """)
        try db.drop(table: "partLink")
        try db.drop(table: "part")
        for definition in definitions { try db.execute(sql: definition) }
        try db.execute(
            sql: """
                INSERT INTO partRequirement (id, jobID, description, quantity,
                    manufacturerReference, compatibility, status, orderedAt, arrivedAt,
                    installedAt, createdAt, updatedAt)
                SELECT id, jobID, name, quantity, description, 'Unchecked',
                    CASE stage WHEN 'In hand' THEN 'Arrived' WHEN 'Fitted' THEN 'Installed'
                        ELSE stage END,
                    orderedAt, inHandAt, fittedAt, createdAt, updatedAt
                FROM part_copy
                """)
        try db.execute(
            sql: """
                INSERT INTO partLink (id, partID, position, url, createdAt, updatedAt)
                SELECT id, partID, position, url, createdAt, updatedAt FROM partLink_copy
                """)
        try db.execute(sql: "DROP TABLE part_copy")
        try db.execute(sql: "DROP TABLE partLink_copy")
        try SearchKey.backfill(
            "partRequirement", fields: ["description", "manufacturerReference"], in: db)
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v26-parts'")
    }
}

// A library and a backup package made by the schema before v26. Its parts are in all five old
// states and hold every removed field: compatibilities with notes, order references, status
// reasons, a date that its state no longer keeps, saved links, and two cancelled parts, one
// with every value and one with none. One job already has notes under "From the old record".
nonisolated enum LegacyPartFixture {
    private static let lastMigration = "v25-jobs-without-watch"

    struct Job {
        let id: String
        let watchID: String
        let title: String
        let stage: String
        var doneAt: Double? = nil
        var notes = ""
        // The notes once the job's cancelled parts are in them.
        let expected: String

        func expectedNotes() -> String { expected }
    }

    struct Part {
        let id: String
        let jobID: String
        let description: String
        var quantity = 1
        var reference: String? = nil
        var compatibility = "Unchecked"
        var compatibilityNote: String? = nil
        let status: String
        var orderedAt: Double? = nil
        var arrivedAt: Double? = nil
        var installedAt: Double? = nil
        var cancelledAt: Double? = nil
        var orderReference: String? = nil
        var statusReason: String? = nil
        let createdAt: Double
        var expectedPosition = 0
        // The lines the part's own notes get, or nil when it gets none.
        var expectedLines: [String]? = nil

        // Arrived becomes In hand, Installed becomes Fitted, and a cancelled part is not kept.
        var expectedStage: PartStage? {
            switch status {
            case "Needed": .needed
            case "Ordered": .ordered
            case "Arrived": .inHand
            case "Installed": .fitted
            default: nil
            }
        }
        var expectedOrderedAt: Double? {
            expectedStage?.hasReached(.ordered) == true ? orderedAt : nil
        }
        var expectedInHandAt: Double? {
            expectedStage?.hasReached(.inHand) == true ? arrivedAt : nil
        }
        var expectedFittedAt: Double? {
            expectedStage?.hasReached(.fitted) == true ? installedAt : nil
        }

        func expectedNotes() -> String {
            guard let expectedLines else { return "" }
            return OldRecordNotes.heading + "\n\n" + expectedLines.joined(separator: "\n")
        }
    }

    struct Link {
        let id: String
        let partID: String
        let position: Int
        let url: String
    }

    static let watches = [
        "00000000-0000-4000-8000-000000002601", "00000000-0000-4000-8000-000000002602",
    ]

    static var jobs: [Job] {
        [
            Job(
                id: "00000000-0000-4000-8000-000000002611", watchID: watches[0],
                title: "Full service", stage: "In progress",
                expected: """
                    From the old record

                    Part · Hands
                    Quantity: 2
                    Manufacturer reference: H-12
                    Compatibility: Confirmed
                    Compatibility note: Matched to the dial
                    Order reference: PO-1190
                    Cancelled: Owner kept the old hands
                    Cancelled on \(day(cancelled))
                    Link: https://example.org/hands/h-12
                    """),
            Job(
                id: "00000000-0000-4000-8000-000000002612", watchID: watches[1],
                title: "New crown", stage: "Done", doneAt: 1_792_000_000,
                notes: "From the old record\nOutcome: Fitted.",
                expected: "From the old record\nOutcome: Fitted.\n\nPart · Strap\nCancelled"),
        ]
    }

    private static let jobA = "00000000-0000-4000-8000-000000002611"
    private static let jobB = "00000000-0000-4000-8000-000000002612"
    private static let ordered = 1_790_000_000.0
    private static let arrived = 1_790_400_000.0
    private static let installed = 1_790_800_000.0
    private static let cancelled = 1_791_000_000.0

    static var parts: [Part] {
        [
            Part(
                id: "00000000-0000-4000-8000-000000002621", jobID: jobA,
                description: "Mainspring", reference: "GR 3800", status: "Needed",
                createdAt: 20, expectedPosition: 0),
            Part(
                id: "00000000-0000-4000-8000-000000002622", jobID: jobA, description: "Crystal",
                compatibility: "Confirmed", compatibilityNote: "Fits 30.0 mm, per Sternkreuz",
                status: "Ordered", orderedAt: ordered, orderReference: "PO-1182",
                createdAt: 21, expectedPosition: 1,
                expectedLines: [
                    "Compatibility: Confirmed", "Compatibility note: Fits 30.0 mm, per Sternkreuz",
                    "Order reference: PO-1182",
                ]),
            Part(
                id: "00000000-0000-4000-8000-000000002623", jobID: jobA, description: "Gaskets",
                quantity: 3, reference: "0012-Å", compatibility: "Unsuitable",
                compatibilityNote: "Wrong section", status: "Arrived", orderedAt: ordered,
                arrivedAt: arrived, statusReason: "Arrived damaged, reordered", createdAt: 22,
                expectedPosition: 2,
                expectedLines: [
                    "Compatibility: Unsuitable", "Compatibility note: Wrong section",
                    "Status reason: Arrived damaged, reordered",
                ]),
            Part(
                id: "00000000-0000-4000-8000-000000002624", jobID: jobB, description: "Crown",
                status: "Installed", orderedAt: ordered, arrivedAt: arrived,
                installedAt: installed, createdAt: 23, expectedPosition: 0),
            Part(
                id: "00000000-0000-4000-8000-000000002625", jobID: jobA, description: "Hands",
                quantity: 2, reference: "H-12", compatibility: "Confirmed",
                compatibilityNote: "Matched to the dial", status: "Cancelled",
                cancelledAt: cancelled, orderReference: "PO-1190",
                statusReason: "Owner kept the old hands", createdAt: 24),
            Part(
                id: "00000000-0000-4000-8000-000000002626", jobID: jobB, description: "Strap",
                status: "Cancelled", createdAt: 25),
            // A corrected part that went back to Needed and kept its order date.
            Part(
                id: "00000000-0000-4000-8000-000000002627", jobID: jobA, description: "Stem",
                status: "Needed", orderedAt: ordered, createdAt: 26, expectedPosition: 3,
                expectedLines: ["Ordered on \(day(ordered))"]),
        ]
    }

    // A day as the migration writes it, such as "3 November 2026".
    private static func day(_ seconds: Double) -> String {
        var calendar = Locale.current.calendar
        calendar.timeZone = .current
        return Date(timeIntervalSince1970: seconds).formatted(
            Date.FormatStyle(
                date: .long, time: .omitted, locale: .current, calendar: calendar,
                timeZone: .current))
    }

    static let links = [
        Link(
            id: "00000000-0000-4000-8000-000000002631",
            partID: "00000000-0000-4000-8000-000000002621", position: 0,
            url: "https://example.org/mainsprings/gr3800"),
        Link(
            id: "00000000-0000-4000-8000-000000002632",
            partID: "00000000-0000-4000-8000-000000002621", position: 1,
            url: "https://example.net/identify?ref=GR%203800"),
        Link(
            id: "00000000-0000-4000-8000-000000002633",
            partID: "00000000-0000-4000-8000-000000002624", position: 0,
            url: "https://example.org/crowns"),
        Link(
            id: "00000000-0000-4000-8000-000000002634",
            partID: "00000000-0000-4000-8000-000000002625", position: 0,
            url: "https://example.org/hands/h-12"),
    ]

    static func old(
        id: String = UUID().uuidString, jobID: String = UUID().uuidString,
        description: String = "Spring", quantity: Int = 1, reference: String? = nil,
        compatibility: String = "Unchecked", compatibilityNote: String? = nil, status: String,
        orderedAt: Double? = nil, arrivedAt: Double? = nil, installedAt: Double? = nil,
        cancelledAt: Double? = nil, orderReference: String? = nil, statusReason: String? = nil,
        createdAt: Double = 0
    ) -> PartMigration.OldPart {
        let row: Row = [
            "id": id, "jobID": jobID, "description": description, "quantity": quantity,
            "manufacturerReference": reference, "compatibility": compatibility,
            "compatibilityNote": compatibilityNote, "status": status, "orderedAt": orderedAt,
            "arrivedAt": arrivedAt, "installedAt": installedAt, "cancelledAt": cancelledAt,
            "orderReference": orderReference, "statusReason": statusReason,
            "createdAt": createdAt, "updatedAt": createdAt + 1,
        ]
        return PartMigration.OldPart(row: row)
    }

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
                libraryID: manifest.libraryID, applicationVersion: "before W040",
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
            for (index, id) in watches.enumerated() {
                try db.execute(
                    sql: "INSERT INTO watch (id, name, createdAt, updatedAt) VALUES (?, ?, 1, 2)",
                    arguments: [id, "Watch \(index + 1)"])
            }
            for job in jobs {
                try db.execute(
                    sql: """
                        INSERT INTO job (id, watchID, title, stage, createdAt, updatedAt, doneAt,
                            notes)
                        VALUES (?, ?, ?, ?, 10, 11, ?, ?)
                        """,
                    arguments: [job.id, job.watchID, job.title, job.stage, job.doneAt, job.notes])
            }
            for part in parts {
                try db.execute(
                    sql: """
                        INSERT INTO partRequirement (id, jobID, description, quantity,
                            manufacturerReference, compatibility, compatibilityNote, status,
                            orderedAt, arrivedAt, installedAt, cancelledAt, orderReference,
                            statusReason, createdAt, updatedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        part.id, part.jobID, part.description, part.quantity, part.reference,
                        part.compatibility, part.compatibilityNote, part.status, part.orderedAt,
                        part.arrivedAt, part.installedAt, part.cancelledAt, part.orderReference,
                        part.statusReason, part.createdAt, part.createdAt + 1,
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
            try SearchKey.backfill(
                "partRequirement", fields: ["description", "manufacturerReference"], in: db)
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
