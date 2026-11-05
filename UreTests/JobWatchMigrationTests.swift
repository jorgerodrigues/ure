import CryptoKit
import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct JobWatchMigrationTests {
    @Test
    func upgradeKeepsEveryJobWithItsWatchAndLetsANewJobWaitForOne() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        try LegacyJobWatchFixture.create(at: fixture.root)
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()

        let stored = try await coordinator.read { db in
            (
                jobs: try Row.fetchAll(db, sql: "SELECT * FROM job ORDER BY id").map(
                    StoredJob.init),
                watchColumn: try db.columns(in: "job").first { $0.name == "watchID" },
                steps: try Int.fetchOne(db, sql: "SELECT count(*) FROM checklistStep"),
                parts: try Int.fetchOne(db, sql: "SELECT count(*) FROM partRequirement"),
                items: try Int.fetchOne(db, sql: "SELECT count(*) FROM libraryItem"),
                indexes: try String.fetchAll(
                    db,
                    sql: """
                        SELECT name FROM sqlite_schema WHERE type = 'index' AND tbl_name = 'job'
                            AND name NOT LIKE 'sqlite_%' ORDER BY name
                        """),
                triggers: try String.fetchAll(
                    db, sql: "SELECT name FROM sqlite_schema WHERE type = 'trigger' ORDER BY name"),
                integrity: try String.fetchOne(db, sql: "PRAGMA integrity_check"),
                foreignKeys: try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count,
                migrations: try String.fetchAll(
                    db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
            )
        }
        #expect(stored.migrations.last == "v25-jobs-without-watch")
        #expect(stored.watchColumn?.isNotNull == false)
        #expect(stored.jobs.count == LegacyJobWatchFixture.jobs.count)
        for (row, job) in zip(stored.jobs, LegacyJobWatchFixture.jobs.sorted { $0.id < $1.id }) {
            #expect(row.id == job.id && row.watchID == job.watchID)
            #expect(row.title == job.title && row.stage == job.stage)
            #expect(row.problem == job.problem && row.waitingFor == job.waitingFor)
            #expect(row.doneAt == job.doneAt && row.archivedAt == job.archivedAt)
            #expect(row.createdAt == 10 && row.updatedAt == 11)
            #expect(row.notes == job.notes)
            #expect(row.searchKey == SearchKey.make([job.title, job.notes]))
        }
        #expect(stored.steps == 2 && stored.parts == 1 && stored.items == 1)
        #expect(
            stored.indexes == [
                "job_archivedAt", "job_one_open_per_watch", "job_searchKey", "job_watchID",
            ])
        #expect(stored.triggers == ["watch_cover_insert", "watch_cover_update"])
        #expect(stored.integrity == "ok" && stored.foreignKeys == 0)

        // Each watch still has one open job, and a new job can start without a watch.
        let service = JobService(coordinator: coordinator)
        let waiting = try #require(LegacyJobWatchFixture.jobs.first { $0.stage == "Waiting" })
        let watchID = try #require(waiting.watchID.flatMap(UUID.init(uuidString:)))
        await #expect(throws: JobError.self) { try await service.start(for: watchID) }
        let unwatched = try await service.start(for: nil)
        #expect(unwatched.watchID == nil)
        try await coordinator.close()
    }

    @Test
    func backupMadeBeforeJobsWithoutWatchRestoresEveryJob() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        _ = try await WatchService(coordinator: coordinator).create(named: "Replaced by restore")
        let package = fixture.directory.appending(path: "before-jobs-without-watch.watchbackup")
        try LegacyJobWatchFixture.package(at: package)
        let staged = try await coordinator.stageRestore(from: package)
        #expect(staged.summary.appliedMigrations == ["v25-jobs-without-watch"])
        #expect(staged.summary.counts["job"] == LegacyJobWatchFixture.jobs.count)
        let result = try await coordinator.activateRestore(staged)
        #expect(result.outcome == .restored)
        let restored = result.coordinator
        let jobs = try await restored.read(JobQueries.fetchAll)
        #expect(
            Set(jobs.map(\.id.uuidString)) == Set(LegacyJobWatchFixture.jobs.map(\.id)))
        for old in LegacyJobWatchFixture.jobs {
            let job = jobs.first { $0.id.uuidString == old.id }
            #expect(job?.watchID?.uuidString == old.watchID && job?.title == old.title)
            #expect(job?.stage.rawValue == old.stage && job?.waitingFor == old.waitingFor)
            #expect(
                try await RecordNotesService(coordinator: restored).text(
                    for: .job(try #require(job?.id))) == old.notes)
        }
        try await restored.close()
    }

    @Test
    func upgradeKeepsAWatchCoverTakenFromItsJobAndTheJobsMaterial() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let watchID = try #require(job.watchID)
        let photo = try await MaterialFixture.file(
            try fixture.source(type: .png), for: .job(job.id), in: coordinator)
        try await MaterialService(coordinator: coordinator).setCover(photo.id, for: watchID)
        try await RecordNotesService(coordinator: coordinator).save(
            "Keep this finding", for: .job(job.id))
        let saved = try await coordinator.read { try JobQueries.fetch(job.id, in: $0) }
        try await coordinator.mutate { db, _, _ in
            try JobWatchMigrationFixture.requireWatch(in: db)
        }
        try await coordinator.close()

        let reopened = LibraryCoordinator(root: fixture.root)
        _ = try await reopened.open()
        let watch = try #require(
            try await reopened.read { try WatchQueries.fetch(watchID, in: $0) })
        #expect(watch.coverPhotoID == photo.id)
        #expect(try await reopened.read { try JobQueries.fetch(job.id, in: $0) } == saved)
        #expect(
            try await RecordNotesService(coordinator: reopened).text(for: .job(job.id))
                == "Keep this finding")
        // The cover triggers came back: a photo that is not the watch's own is refused.
        let other = try await JobTaskFixture.job(reopened)
        let otherPhoto = try await MaterialFixture.file(
            try fixture.source(type: .png), for: .job(other.id), in: reopened)
        await #expect(throws: (any Error).self) {
            try await MaterialService(coordinator: reopened).setCover(otherPhoto.id, for: watchID)
        }
        await #expect(throws: DatabaseError.self) {
            try await reopened.mutate { db, _, _ in
                try db.execute(
                    sql: "UPDATE watch SET coverPhotoID = ? WHERE id = ?",
                    arguments: [otherPhoto.id.uuidString, watchID.uuidString])
            }
        }
        try await reopened.close()
    }
}

// A job row as the database holds it.
nonisolated struct StoredJob: Sendable {
    let id: String
    let watchID: String?
    let title: String
    let stage: String
    let problem: String?
    let waitingFor: String?
    let doneAt: Double?
    let createdAt: Double
    let updatedAt: Double
    let archivedAt: Double?
    let notes: String
    let searchKey: String

    init(_ row: Row) {
        id = row["id"]
        watchID = row["watchID"]
        title = row["title"]
        stage = row["stage"]
        problem = row["problem"]
        waitingFor = row["waitingFor"]
        doneAt = row["doneAt"]
        createdAt = row["createdAt"]
        updatedAt = row["updatedAt"]
        archivedAt = row["archivedAt"]
        notes = row["notes"]
        searchKey = row["searchKey"]
    }
}

// Puts a current library back to the schema before v25, where every job has a watch. The job
// table is made again with the same definitions v23 used, so the schema matches v23's exactly,
// and v25 runs again on the next open. The rows go back in after the old table goes, which keeps
// SQLite's deferred foreign key count balanced.
nonisolated enum JobWatchMigrationFixture {
    static func requireWatch(in db: Database) throws {
        try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
        try db.execute(sql: "CREATE TEMP TABLE job_copy AS SELECT * FROM job")
        try db.execute(sql: "DROP TRIGGER watch_cover_insert")
        try db.execute(sql: "DROP TRIGGER watch_cover_update")
        try db.drop(table: "job")
        try db.create(table: "job") { table in
            table.column("id", .text).primaryKey()
            table.column("watchID", .text).notNull().references("watch", onDelete: .restrict)
            table.column("title", .text).notNull().check(sql: "length(trim(title)) > 0")
            table.column("stage", .text).notNull()
                .check(sql: "stage IN ('In progress', 'Waiting', 'Done')")
            table.column("problem", .text)
            table.column("waitingFor", .text)
            for column in ["createdAt", "updatedAt"] {
                table.column(column, .double).notNull()
            }
            table.column("doneAt", .double)
            table.column("searchKey", .text).notNull().defaults(to: "")
            table.column("archivedAt", .double)
            table.column("notes", .text).notNull().defaults(to: "")
            table.check(sql: "stage = 'Waiting' OR waitingFor IS NULL")
            table.check(sql: "(stage = 'Done') = (doneAt IS NOT NULL)")
        }
        try db.execute(
            sql: """
                INSERT INTO job
                    (id, watchID, title, stage, problem, waitingFor, createdAt, updatedAt, doneAt,
                     searchKey, archivedAt, notes)
                SELECT id, watchID, title, stage, problem, waitingFor, createdAt, updatedAt,
                    doneAt, searchKey, archivedAt, notes
                FROM job_copy
                """)
        try db.execute(sql: "DROP TABLE job_copy")
        try db.create(index: "job_watchID", on: "job", columns: ["watchID"])
        try db.execute(
            sql: """
                CREATE UNIQUE INDEX job_one_open_per_watch ON job(watchID)
                WHERE stage IN ('In progress', 'Waiting')
                """)
        try db.create(index: "job_searchKey", on: "job", columns: ["searchKey"])
        try db.create(index: "job_archivedAt", on: "job", columns: ["archivedAt"])
        for operation in ["INSERT", "UPDATE"] {
            try db.execute(
                sql: """
                    CREATE TRIGGER watch_cover_\(operation.lowercased()) BEFORE \(operation) ON watch
                    WHEN NEW.coverPhotoID IS NOT NULL AND NOT EXISTS (
                        SELECT 1 FROM libraryItem AS item
                        LEFT JOIN job ON job.id = item.jobID
                        WHERE item.id = NEW.coverPhotoID AND item.kind = 'Photo'
                          AND (item.watchID = NEW.id OR job.watchID = NEW.id))
                    BEGIN SELECT RAISE(ABORT, 'Invalid watch cover'); END
                    """)
        }
        try db.execute(
            sql: "DELETE FROM grdb_migrations WHERE identifier = 'v25-jobs-without-watch'")
    }
}

// A library and a backup package made by the schema before v25. Every job has a watch: one In
// progress with checklist steps, a part and a link, one Waiting, one Done and one archived.
nonisolated enum LegacyJobWatchFixture {
    private static let lastMigration = "v24-checklist-steps"

    struct Job {
        let id: String
        let watchID: String?
        let title: String
        let stage: String
        var problem: String? = nil
        var waitingFor: String? = nil
        var doneAt: Double? = nil
        var archivedAt: Double? = nil
        var notes = ""
    }

    static let watches = [
        "00000000-0000-4000-8000-000000002401", "00000000-0000-4000-8000-000000002402",
        "00000000-0000-4000-8000-000000002403",
    ]

    static let jobs = [
        Job(
            id: "00000000-0000-4000-8000-000000002411", watchID: watches[0],
            title: "Full service", stage: "In progress",
            problem: "Loses two minutes a day.", notes: "14 October. Mainspring is set."),
        Job(
            id: "00000000-0000-4000-8000-000000002412", watchID: watches[1],
            title: "New crystal", stage: "Waiting", waitingFor: "a mainspring"),
        Job(
            id: "00000000-0000-4000-8000-000000002413", watchID: watches[0],
            title: "Crystal and gaskets", stage: "Done", doneAt: 1_790_000_000,
            notes: "From the old record\nOutcome: Fitted."),
        Job(
            id: "00000000-0000-4000-8000-000000002414", watchID: watches[2],
            title: "Old repair", stage: "Done", doneAt: 1_780_000_000,
            archivedAt: 1_785_000_000),
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
                libraryID: manifest.libraryID, applicationVersion: "before W038",
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
                        INSERT INTO job (id, watchID, title, stage, problem, waitingFor,
                            createdAt, updatedAt, doneAt, archivedAt, notes)
                        VALUES (?, ?, ?, ?, ?, ?, 10, 11, ?, ?, ?)
                        """,
                    arguments: [
                        job.id, job.watchID, job.title, job.stage, job.problem, job.waitingFor,
                        job.doneAt, job.archivedAt, job.notes,
                    ])
            }
            try db.execute(
                sql: """
                    INSERT INTO checklistStep (id, jobID, position, text, isTicked, createdAt,
                        updatedAt)
                    VALUES ('00000000-0000-4000-8000-000000002421', ?, 0, 'Clean', 1, 12, 12),
                        ('00000000-0000-4000-8000-000000002422', ?, 1, 'Oil', 0, 12, 12)
                    """, arguments: [jobs[0].id, jobs[0].id])
            try db.execute(
                sql: """
                    INSERT INTO partRequirement (id, jobID, description, quantity, compatibility,
                        status, createdAt, updatedAt)
                    VALUES ('00000000-0000-4000-8000-000000002431', ?, 'Mainspring', 1,
                        'Unchecked', 'Needed', 12, 12)
                    """, arguments: [jobs[0].id])
            try db.execute(
                sql: """
                    INSERT INTO libraryItem (id, jobID, kind, title, url, createdAt, updatedAt)
                    VALUES ('00000000-0000-4000-8000-000000002441', ?, 'Link',
                        'Dial variants', 'https://example.org/dials', 12, 12)
                    """, arguments: [jobs[0].id])
            try SearchKey.backfill("job", fields: ["title", "notes"], in: db)
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
