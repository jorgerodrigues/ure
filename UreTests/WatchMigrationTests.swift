import CryptoKit
import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct WatchMigrationTests {
    @Test
    func upgradeMovesTheOwnerToTheWatchAndWritesRemovedValuesIntoNotes() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        try LegacyWatchFixture.create(at: fixture.root)
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()

        let watches = try await coordinator.read(WatchQueries.fetchAll)
        #expect(watches.count == LegacyWatchFixture.watches.count)
        let notes = RecordNotesService(coordinator: coordinator)
        for old in LegacyWatchFixture.watches {
            let watch = try #require(watches.first { $0.id == old.id })
            #expect(watch.name == old.name)
            #expect(watch.owner == old.expectedOwner)
            #expect(watch.contact == old.expectedContact)
            #expect(watch.createdAt.timeIntervalSince1970 == old.createdAt)
            #expect(watch.updatedAt.timeIntervalSince1970 == old.createdAt + 1)
            #expect((watch.archivedAt != nil) == old.isArchived)
            #expect(try await notes.text(for: .watch(old.id)) == old.expectedNotes)
        }
        let stored = try await coordinator.read { db in
            (
                watchColumns: try db.columns(in: "watch").map(\.name),
                jobColumns: try db.columns(in: "job").map(\.name),
                jobs: try JobQueries.fetchAll(db)
            )
        }
        for column in ["condition", "conditionNote", "waterResistance", "specificationNotes"] {
            #expect(!stored.watchColumns.contains(column))
        }
        #expect(stored.watchColumns.suffix(2) == ["owner", "contact"])
        for column in ["ownerName", "ownerEmail", "ownerPhone"] {
            #expect(!stored.jobColumns.contains(column))
        }
        #expect(stored.jobs.count == LegacyWatchFixture.jobs.count)
        for old in LegacyWatchFixture.jobs {
            let job = try #require(stored.jobs.first { $0.id == old.id })
            #expect(job.watchID == old.watchID && job.title == old.title)
            #expect(job.stage.rawValue == old.stage)
            #expect(job.updatedAt.timeIntervalSince1970 == old.createdAt)
        }
        // The owner is searchable on the watch, and older owners through the watch's notes.
        #expect(
            Set(
                try await coordinator.read { try SearchQueries.fetch("ribeiro", in: $0) }.map(
                    \.recordID)) == [
                    LegacyWatchFixture.watches[1].id, LegacyWatchFixture.watches[2].id,
                ])
        #expect(
            try await coordinator.read { try SearchQueries.fetch("balance staff", in: $0) }.map(
                \.recordID) == [LegacyWatchFixture.watches[0].id])
        #expect(
            try await coordinator.read { try SearchQueries.fetch("+45 0012", in: $0) }.map(
                \.recordID) == [LegacyWatchFixture.watches[3].id])
        try await coordinator.close()
    }

    @Test
    func backupMadeBeforeTheWatchOwnerRestoresWithTheRemovedValuesInNotes() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        _ = try await WatchService(coordinator: coordinator).create(named: "Replaced by restore")
        let package = fixture.directory.appending(path: "before-watch-owner.watchbackup")
        try LegacyWatchFixture.package(at: package)
        let staged = try await coordinator.stageRestore(from: package)
        #expect(staged.summary.appliedMigrations == ["v22-watch-owner"])
        #expect(staged.summary.counts["watch"] == LegacyWatchFixture.watches.count)
        #expect(staged.summary.counts["job"] == LegacyWatchFixture.jobs.count)
        let result = try await coordinator.activateRestore(staged)
        #expect(result.outcome == .restored)
        let restored = result.coordinator
        let watches = try await restored.read(WatchQueries.fetchAll)
        #expect(Set(watches.map(\.id)) == Set(LegacyWatchFixture.watches.map(\.id)))
        let notes = RecordNotesService(coordinator: restored)
        for old in LegacyWatchFixture.watches {
            let watch = watches.first { $0.id == old.id }
            #expect(watch?.owner == old.expectedOwner && watch?.contact == old.expectedContact)
            #expect(try await notes.text(for: .watch(old.id)) == old.expectedNotes)
        }
        try await restored.close()
    }

    @Test
    func theOwnerComesFromTheNewestJobThatNamesOne() {
        typealias Owner = WatchMigration.Owner
        let ana = Owner(name: "Ana Ribeiro", email: "ana@example.pt", phone: "+351 912")
        let jobs = [
            WatchMigration.Job(title: "Newest", owner: Owner(name: " ", email: nil, phone: "")),
            WatchMigration.Job(title: "Full service", owner: ana),
            WatchMigration.Job(title: "Strap", owner: ana),
            WatchMigration.Job(
                title: "Crystal", owner: Owner(name: "Ana Ribeiro", email: "old@x.pt", phone: nil)),
            WatchMigration.Job(
                title: "First service", owner: Owner(name: "José", email: nil, phone: "21 0")),
        ]
        #expect(WatchMigration.currentOwner(of: []) == nil)
        #expect(WatchMigration.currentOwner(of: Array(jobs.prefix(1))) == nil)
        #expect(WatchMigration.currentOwner(of: jobs) == ana)
        #expect(ana.contact == "ana@example.pt · +351 912")
        #expect(Owner(name: "Ana", email: nil, phone: " 21 0\n").contact == " 21 0")
        #expect(Owner(name: "Ana", email: nil, phone: nil).contact == nil)
        #expect(
            WatchMigration.otherOwners(in: jobs, keeping: ana) == [
                "Job · First service\nOwner: José\nPhone: 21 0",
                "Job · Crystal\nOwner: Ana Ribeiro\nEmail: old@x.pt",
            ])
        #expect(WatchMigration.otherOwners(in: Array(jobs.prefix(3)), keeping: ana).isEmpty)
    }

    @Test
    func eachWatchWritesOnlyTheValuesThatGo() {
        #expect(
            WatchMigration.entry(
                condition: "Unknown", conditionNote: " \n", waterResistance: "",
                specificationNotes: nil) == nil)
        #expect(
            WatchMigration.entry(
                condition: "Running poorly", conditionNote: nil, waterResistance: nil,
                specificationNotes: nil) == "Condition: Running poorly")
        #expect(
            WatchMigration.entry(
                condition: "Unknown", conditionNote: "  Loses a minute a day.\n\n",
                waterResistance: "3 atm", specificationNotes: "Unsigned dial.\nCheck the back.")
                == "Condition note:   Loses a minute a day.\nWater resistance: 3 atm\n"
                + "Specification notes: Unsigned dial.\nCheck the back.")
    }
}

// Puts a current library back to the schema before v22, with the watch and job fields that v22
// drops.
nonisolated enum WatchMigrationFixture {
    static func restoreWatchFields(in db: Database) throws {
        try db.alter(table: "watch") { table in
            table.add(column: "condition", .text).notNull().defaults(to: "Unknown")
                .check(
                    sql:
                        "condition IN ('Unknown', 'Running', 'Running poorly', 'Stopped', 'Disassembled')"
                )
            for column in ["conditionNote", "waterResistance", "specificationNotes"] {
                table.add(column: column, .text)
            }
        }
        try db.alter(table: "job") { table in
            for column in ["ownerName", "ownerEmail", "ownerPhone"] {
                table.add(column: column, .text)
            }
        }
        // Each watch's owner goes back on its newest job, so v22 can move it again.
        try db.execute(
            sql: """
                UPDATE job SET
                    ownerName = (SELECT owner FROM watch WHERE watch.id = job.watchID),
                    ownerEmail = (SELECT contact FROM watch WHERE watch.id = job.watchID)
                WHERE id = (
                    SELECT newest.id FROM job AS newest WHERE newest.watchID = job.watchID
                    ORDER BY newest.createdAt DESC, newest.id LIMIT 1)
                """)
        try db.alter(table: "watch") { table in
            table.drop(column: "owner")
            table.drop(column: "contact")
        }
        try SearchKey.backfill(
            "watch",
            fields: [
                "name", "brand", "model", "caseReference", "serial", "approximateYear", "notes",
            ], in: db)
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v22-watch-owner'")
    }
}

// A library and a backup package made by the schema before v22. The watches have no jobs, one
// job, and several jobs with different owners, emails and phones, with every watch field that
// v22 removes, blank values, and notes that already hold values from an older record.
nonisolated enum LegacyWatchFixture {
    private static let lastMigration = "v21-caliber-facts"

    struct Watch {
        let id: UUID
        let name: String
        var condition = "Unknown"
        var conditionNote: String?
        var waterResistance: String?
        var specificationNotes: String?
        var notes = ""
        var isArchived = false
        let createdAt: Double
        var expectedOwner: String?
        var expectedContact: String?
        let expectedNotes: String
    }

    struct Job {
        let id: UUID
        let watchID: UUID
        let title: String
        var stage = "Completed"
        var ownerName: String?
        var ownerEmail: String?
        var ownerPhone: String?
        let createdAt: Double
    }

    static let watches = [
        Watch(
            id: id(0x01), name: "No jobs", condition: "Stopped",
            conditionNote: "Balance staff broken.\n", waterResistance: "3 atm (unverified)",
            specificationNotes: "Unsigned dial.\nCheck the case back.",
            notes: "Bought at auction.", createdAt: 10,
            expectedNotes: "Bought at auction.\n\nFrom the old record\n\nCondition: Stopped\n"
                + "Condition note: Balance staff broken.\nWater resistance: 3 atm (unverified)\n"
                + "Specification notes: Unsigned dial.\nCheck the case back."),
        Watch(
            id: id(0x02), name: "One job", createdAt: 11, expectedOwner: "Ana Ribeiro",
            expectedContact: "ana@example.pt · +351 912 480 117", expectedNotes: ""),
        Watch(
            id: id(0x03), name: "Several jobs", condition: "Running",
            notes: "From the old record\n\nPhoto · Dial", createdAt: 12,
            expectedOwner: "Ana Ribeiro", expectedContact: "ana@example.pt",
            expectedNotes: "From the old record\n\nPhoto · Dial\n\nCondition: Running\n\n"
                + "Job · Strap\nOwner: Ana Ribeiro\nEmail: ana@old.pt\n\n"
                + "Job · First service\nOwner: José Ribeiro\nPhone: +351 21 000 0000"),
        Watch(
            id: id(0x04), name: "Phone only", waterResistance: "  ", specificationNotes: "",
            isArchived: true, createdAt: 13, expectedContact: "+45 0012", expectedNotes: ""),
    ]

    static let jobs = [
        Job(
            id: id(0x11), watchID: watches[1].id, title: "Full service", stage: "In progress",
            ownerName: "Ana Ribeiro", ownerEmail: "ana@example.pt",
            ownerPhone: "+351 912 480 117", createdAt: 30),
        Job(
            id: id(0x21), watchID: watches[2].id, title: "Strap", ownerName: "Ana Ribeiro",
            ownerEmail: "ana@old.pt", createdAt: 19),
        Job(
            id: id(0x22), watchID: watches[2].id, title: "First service",
            ownerName: "José Ribeiro", ownerPhone: "+351 21 000 0000", createdAt: 20),
        Job(
            id: id(0x23), watchID: watches[2].id, title: "Crystal", ownerName: "Ana Ribeiro",
            ownerEmail: "ana@example.pt", createdAt: 21),
        Job(
            id: id(0x24), watchID: watches[2].id, title: "Full service",
            ownerName: "Ana Ribeiro", ownerEmail: "ana@example.pt", createdAt: 22),
        Job(
            id: id(0x25), watchID: watches[2].id, title: "Check", stage: "Waiting",
            ownerName: "  ", ownerEmail: "", createdAt: 23),
        Job(
            id: id(0x31), watchID: watches[3].id, title: "Battery", ownerPhone: "  +45 0012 ",
            createdAt: 40),
    ]

    private static func id(_ last: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0x36, last))
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
                libraryID: manifest.libraryID, applicationVersion: "before W036",
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
            for watch in watches { try insert(watch, in: db) }
            for job in jobs { try insert(job, in: db) }
            try SearchKey.backfill(
                "watch",
                fields: [
                    "name", "brand", "model", "caseReference", "serial", "approximateYear",
                    "notes",
                ], in: db)
        }
        try database.close()
        return manifest
    }

    private static func insert(_ watch: Watch, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO watch (id, name, condition, conditionNote, waterResistance,
                    specificationNotes, notes, createdAt, updatedAt, archivedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                watch.id.uuidString, watch.name, watch.condition, watch.conditionNote,
                watch.waterResistance, watch.specificationNotes, watch.notes, watch.createdAt,
                watch.createdAt + 1, watch.isArchived ? watch.createdAt + 2 : nil,
            ])
    }

    private static func insert(_ job: Job, in db: Database) throws {
        let snapshot = try String(
            decoding: JSONEncoder().encode(
                JobIntakeSnapshot(
                    watchName: job.title, brand: nil, model: nil, caseReference: nil,
                    serial: nil, caliberDesignation: nil, caliberVariant: nil)),
            as: UTF8.self)
        try db.execute(
            sql: """
                INSERT INTO job (id, watchID, title, stage, ownerName, ownerEmail, ownerPhone,
                    intakeSnapshot, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                job.id.uuidString, job.watchID.uuidString, job.title, job.stage, job.ownerName,
                job.ownerEmail, job.ownerPhone, snapshot, job.createdAt, job.createdAt,
            ])
    }

    private static func fingerprint(_ file: URL, path: String) throws -> SnapshotFile {
        let bytes = try Data(contentsOf: file)
        return SnapshotFile(
            path: path, byteCount: Int64(bytes.count),
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
}
