import CryptoKit
import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct CaliberMigrationTests {
    @Test
    func upgradeKeepsEveryWindingAndWritesRemovedFieldsIntoNotes() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        try LegacyCaliberFixture.create(at: fixture.root)
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()

        let calibers = try await coordinator.read(CaliberQueries.fetchAll)
        #expect(calibers.count == LegacyCaliberFixture.calibers.count)
        let notes = RecordNotesService(coordinator: coordinator)
        for old in LegacyCaliberFixture.calibers {
            let caliber = try #require(calibers.first { $0.id == old.id })
            #expect(caliber.designation == old.designation)
            #expect(caliber.manufacturer == old.manufacturer)
            #expect(caliber.winding == old.winding)
            #expect(caliber.beatRate == old.beatRate && caliber.liftAngle == old.liftAngle)
            #expect(caliber.jewelCount == old.jewelCount)
            #expect(caliber.powerReserve == old.powerReserve)
            #expect(caliber.createdAt.timeIntervalSince1970 == old.createdAt)
            #expect(caliber.updatedAt.timeIntervalSince1970 == old.createdAt + 1)
            #expect(try await notes.text(for: .caliber(old.id)) == old.expectedNotes)
        }
        let stored = try await coordinator.read { db in
            (
                columns: try db.columns(in: "caliber").map(\.name),
                watch: try WatchQueries.fetch(LegacyCaliberFixture.watchID, in: db)
            )
        }
        #expect(
            stored.columns == [
                "id", "designation", "manufacturer", "beatRate", "liftAngle", "jewelCount",
                "powerReserve", "createdAt", "updatedAt", "searchKey", "archivedAt", "notes",
                "winding",
            ])
        #expect(stored.watch?.caliberID == LegacyCaliberFixture.calibers[0].id)
        #expect(
            try await coordinator.read { try SearchQueries.fetch("Elaboré", in: $0) }.map(
                \.recordID) == [LegacyCaliberFixture.calibers[2].id])
        #expect(
            try await coordinator.read { try SearchQueries.fetch("Ronda", in: $0) }.map(
                \.recordID) == [LegacyCaliberFixture.calibers[3].id])
        await #expect(throws: DatabaseError.self) {
            try await coordinator.mutate { db, _, _ in
                try db.execute(sql: "UPDATE caliber SET winding = 'Other'")
            }
        }
        try await coordinator.close()
    }

    @Test
    func backupMadeBeforeCaliberFactsRestoresWithTheRemovedValuesInNotes() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        _ = try await CaliberService(coordinator: coordinator).create(
            named: "Replaced by the restore")
        let package = fixture.directory.appending(path: "before-caliber-facts.watchbackup")
        try LegacyCaliberFixture.package(at: package)
        let staged = try await coordinator.stageRestore(from: package)
        #expect(
            staged.summary.appliedMigrations == [
                "v21-caliber-facts", "v22-watch-owner", "v23-job-states", "v24-checklist-steps",
            ])
        #expect(staged.summary.counts["caliber"] == LegacyCaliberFixture.calibers.count)
        let result = try await coordinator.activateRestore(staged)
        #expect(result.outcome == .restored)
        let restored = result.coordinator
        let calibers = try await restored.read(CaliberQueries.fetchAll)
        #expect(Set(calibers.map(\.id)) == Set(LegacyCaliberFixture.calibers.map(\.id)))
        let notes = RecordNotesService(coordinator: restored)
        for old in LegacyCaliberFixture.calibers {
            #expect(calibers.first { $0.id == old.id }?.winding == old.winding)
            #expect(try await notes.text(for: .caliber(old.id)) == old.expectedNotes)
        }
        try await restored.close()
    }

    @Test
    func eachCaliberWritesOnlyTheValuesThatGo() {
        for type in ["Unknown", "Manual", "Automatic", "Quartz"] {
            #expect(
                CaliberMigration.entry(
                    variant: nil, movementType: type, specificationNotes: nil, sourceNote: nil)
                    == nil)
        }
        #expect(
            CaliberMigration.entry(
                variant: " \n", movementType: "Other", specificationNotes: "",
                sourceNote: "  ") == "Movement type: Other")
        #expect(
            CaliberMigration.entry(
                variant: "A/2", movementType: "Manual",
                specificationNotes: "  Indented.\nSecond line.\n\n",
                sourceNote: "Maker's sheet")
                == "Variant: A/2\nSpecification notes:   Indented.\nSecond line.\n"
                + "Source note: Maker's sheet")
    }

    @Test
    func oldRecordValuesGoUnderOneHeading() {
        let heading = OldRecordNotes.heading
        #expect(OldRecordNotes.appending(["A"], to: "") == "\(heading)\n\nA")
        #expect(OldRecordNotes.appending(["A"], to: "Text") == "Text\n\n\(heading)\n\nA")
        #expect(OldRecordNotes.appending(["A"], to: "Text\n") == "Text\n\n\(heading)\n\nA")
        #expect(
            OldRecordNotes.appending(["A", "B"], to: "Text\n\n") == "Text\n\n\(heading)\n\nA\n\nB")
        #expect(
            OldRecordNotes.appending(["B"], to: "Text\n\n\(heading)\n\nA")
                == "Text\n\n\(heading)\n\nA\n\nB")
        #expect(
            OldRecordNotes.appending(["B"], to: "Not the \(heading)")
                == "Not the \(heading)\n\n\(heading)\n\nB")
        #expect(OldRecordNotes.appending([], to: "Text ") == "Text ")
    }
}

// Puts a current library back to the schema before v21, with the caliber fields that v21 drops.
nonisolated enum CaliberMigrationFixture {
    static func restoreCaliberFields(in db: Database) throws {
        try WatchMigrationFixture.restoreWatchFields(in: db)
        try db.alter(table: "caliber") { table in
            for column in ["variant", "specificationNotes", "sourceNote"] {
                table.add(column: column, .text)
            }
            table.add(column: "movementType", .text).notNull().defaults(to: "Unknown")
                .check(
                    sql: "movementType IN ('Unknown', 'Manual', 'Automatic', 'Quartz', 'Other')")
        }
        try db.execute(sql: "UPDATE caliber SET movementType = coalesce(winding, 'Unknown')")
        try db.alter(table: "caliber") { table in table.drop(column: "winding") }
        try SearchKey.backfill(
            "caliber", fields: ["designation", "manufacturer", "variant", "notes"], in: db)
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v21-caliber-facts'")
    }
}

// A library and a backup package made by the schema before v21. The calibers have every
// movement type, every field that v21 removes, blank values, and notes that already hold
// values from an older record.
nonisolated enum LegacyCaliberFixture {
    static let watchID = id(0x10)
    private static let lastMigration = "v20-material"

    struct Caliber {
        let id: UUID
        let designation: String
        var manufacturer: String?
        var variant: String?
        let movementType: String
        var beatRate: Double?
        var jewelCount: Double?
        var powerReserve: Double?
        var liftAngle: Double?
        var specificationNotes: String?
        var sourceNote: String?
        var notes = ""
        let createdAt: Double
        let expectedNotes: String

        var winding: Winding? { Winding(rawValue: movementType) }
    }

    static let calibers = [
        Caliber(
            id: id(0x01), designation: "552", manufacturer: "Omega", movementType: "Automatic",
            beatRate: 19_800, jewelCount: 24, powerReserve: 50, liftAngle: 52,
            notes: "Shared caliber knowledge.", createdAt: 10,
            expectedNotes: "Shared caliber knowledge."),
        Caliber(
            id: id(0x02), designation: "6498", manufacturer: "Unitas", movementType: "Manual",
            specificationNotes: "Hacking added in later batches.\nCheck the bridge.\n\n",
            createdAt: 11,
            expectedNotes: "From the old record\n\n"
                + "Specification notes: Hacking added in later batches.\nCheck the bridge."),
        Caliber(
            id: id(0x03), designation: "2824-2", manufacturer: "ETA", variant: "Elaboré",
            movementType: "Unknown", beatRate: 28_800, sourceNote: "  ", notes: "Bought a spare.\n",
            createdAt: 12,
            expectedNotes: "Bought a spare.\n\nFrom the old record\n\nVariant: Elaboré"),
        Caliber(
            id: id(0x04), designation: "715", manufacturer: "Ronda", movementType: "Quartz",
            sourceNote: "Ronda catalogue, page 4", notes: "From the old record\n\nPDF · Sheet",
            createdAt: 13,
            expectedNotes: "From the old record\n\nPDF · Sheet\n\n"
                + "Source note: Ronda catalogue, page 4"),
        Caliber(
            id: id(0x05), designation: "Tuning fork", variant: "  ", movementType: "Other",
            specificationNotes: "360 Hz.", sourceNote: "Seller’s photo", createdAt: 14,
            expectedNotes: "From the old record\n\n"
                + "Movement type: Other\nSpecification notes: 360 Hz.\nSource note: Seller’s photo"
        ),
        Caliber(
            id: id(0x06), designation: "Unknown movement", movementType: "Unknown",
            createdAt: 15, expectedNotes: ""),
    ]

    private static func id(_ last: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0x35, last))
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
                exportedAt: Date(timeIntervalSince1970: 1_792_000_000),
                libraryID: manifest.libraryID, applicationVersion: "before W035",
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
            for caliber in calibers { try insert(caliber, in: db) }
            try db.execute(
                sql: """
                    INSERT INTO watch (id, name, caliberID, notes, createdAt, updatedAt)
                    VALUES (?, 'Seamaster', ?, '', 10, 11)
                    """, arguments: [watchID.uuidString, calibers[0].id.uuidString])
            try SearchKey.backfill(
                "caliber", fields: ["designation", "manufacturer", "variant", "notes"], in: db)
        }
        try database.close()
        return manifest
    }

    private static func insert(_ caliber: Caliber, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO caliber (id, designation, manufacturer, variant, movementType,
                    beatRate, jewelCount, powerReserve, liftAngle, specificationNotes,
                    sourceNote, notes, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                caliber.id.uuidString, caliber.designation, caliber.manufacturer, caliber.variant,
                caliber.movementType, caliber.beatRate, caliber.jewelCount, caliber.powerReserve,
                caliber.liftAngle, caliber.specificationNotes, caliber.sourceNote, caliber.notes,
                caliber.createdAt, caliber.createdAt + 1,
            ])
    }

    private static func fingerprint(_ file: URL, path: String) throws -> SnapshotFile {
        let bytes = try Data(contentsOf: file)
        return SnapshotFile(
            path: path, byteCount: Int64(bytes.count),
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
}
