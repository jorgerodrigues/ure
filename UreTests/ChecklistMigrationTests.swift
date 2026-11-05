import CryptoKit
import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct ChecklistMigrationTests {
    @Test
    func upgradeTurnsEveryTaskIntoAStepInOrderUnderItsGroupHeading() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        try LegacyChecklistFixture.create(at: fixture.root)
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()

        let steps = try await coordinator.read(ChecklistQueries.fetchAll)
        for job in LegacyChecklistFixture.jobs {
            let lines = steps.filter { $0.jobID == job.id }.sorted { $0.position < $1.position }
            #expect(lines.map(\.position) == Array(lines.indices))
            #expect(
                lines.map(LegacyChecklistFixture.Line.init) == job.expectedLines, "\(job.title)")
            // Each step keeps its task's ID and times. A heading takes the times of the step
            // under it.
            for task in job.tasks {
                let step = try #require(lines.first { $0.id == task.id })
                #expect(step.createdAt.timeIntervalSince1970 == task.createdAt)
                #expect(step.updatedAt.timeIntervalSince1970 == task.createdAt + 1)
            }
        }
        let notes = RecordNotesService(coordinator: coordinator)
        let jobs = try await coordinator.read(JobQueries.fetchAll)
        for old in LegacyChecklistFixture.jobs {
            #expect(try await notes.text(for: .job(old.id)) == old.expectedNotes, "\(old.title)")
            // The migration does not change when the job was last edited.
            #expect(jobs.first { $0.id == old.id }?.updatedAt.timeIntervalSince1970 == 3)
        }
        let stored = try await coordinator.read { db in
            (
                tables: try String.fetchAll(
                    db, sql: "SELECT name FROM sqlite_schema WHERE type = 'table'"),
                columns: try db.columns(in: "checklistStep").map(\.name),
                parts: try PartRecord.fetchAll(db, sql: "SELECT * FROM partRequirement"),
                integrity: try String.fetchOne(db, sql: "PRAGMA integrity_check"),
                foreignKeys: try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
            )
        }
        #expect(!stored.tables.contains("jobTask") && !stored.tables.contains("taskPart"))
        #expect(
            stored.columns == [
                "id", "jobID", "position", "text", "isHeading", "isTicked", "createdAt",
                "updatedAt",
            ])
        // The parts stay as they were. Only the links between tasks and parts go.
        #expect(Set(stored.parts.map(\.id)) == Set(LegacyChecklistFixture.parts.map(\.id)))
        #expect(stored.integrity == "ok" && stored.foreignKeys == 0)
        // A reason moved into the notes is found through the job.
        #expect(
            try await coordinator.read { try SearchQueries.fetch("mainspring on order", in: $0) }
                .map(\.recordID) == [LegacyChecklistFixture.jobs[0].id])
        // Done and skipped tasks are ticked steps. Headings do not count.
        let progress = ChecklistProgress(
            records: steps.filter { $0.jobID == LegacyChecklistFixture.jobs[0].id })
        #expect(progress.summary == "3 of 8 done")
        try await coordinator.close()
    }

    @Test
    func backupMadeBeforeChecklistsRestoresWithTheStepsAndTheReasonsInNotes() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        _ = try await WatchService(coordinator: coordinator).create(named: "Replaced by restore")
        let package = fixture.directory.appending(path: "before-checklists.watchbackup")
        try LegacyChecklistFixture.package(at: package)
        let staged = try await coordinator.stageRestore(from: package)
        #expect(staged.summary.appliedMigrations == ["v24-checklist-steps"])
        #expect(
            staged.summary.counts["checklistStep"]
                == LegacyChecklistFixture.jobs.map(\.expectedLines.count).reduce(0, +))
        #expect(staged.summary.counts["jobTask"] == nil && staged.summary.counts["taskPart"] == nil)
        let result = try await coordinator.activateRestore(staged)
        #expect(result.outcome == .restored)
        let restored = result.coordinator
        let steps = try await restored.read(ChecklistQueries.fetchAll)
        let notes = RecordNotesService(coordinator: restored)
        for job in LegacyChecklistFixture.jobs {
            let lines = steps.filter { $0.jobID == job.id }.sorted { $0.position < $1.position }
            #expect(lines.map(LegacyChecklistFixture.Line.init) == job.expectedLines)
            #expect(try await notes.text(for: .job(job.id)) == job.expectedNotes)
        }
        try await restored.close()
    }

    // Every test that takes a library back to an older schema starts with this reversal, so it
    // must leave exactly the schema before v24.
    @Test
    func theReversalLeavesTheSchemaBeforeChecklists() async throws {
        let current = try DatabaseQueue()
        try LibrarySchema.migrator.migrate(current)
        try await current.write { db in
            try ChecklistMigrationFixture.restoreTasks(in: db)
        }
        let before = try DatabaseQueue()
        try LibrarySchema.migrator.migrate(before, upTo: "v23-job-states")
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
    func eachTaskWritesOnlyTheValuesThatGo() {
        #expect(
            ChecklistMigration.entry(
                title: "Clean", detail: " \n", waitingReason: nil, skippedReason: "") == nil)
        #expect(
            ChecklistMigration.entry(
                title: "Clean", detail: "Rinse twice  \n", waitingReason: "Cleaner fluid",
                skippedReason: "Already clean")
                == "Step · Clean\nDetail: Rinse twice\nWaiting reason: Cleaner fluid\n"
                + "Skipped reason: Already clean")
        #expect(ChecklistMigration.heading("  Cleaning ") == "Cleaning")
        #expect(ChecklistMigration.heading(" \n") == nil && ChecklistMigration.heading(nil) == nil)
    }
}

// Puts a current library back to the schema before v24: tasks with group labels and links to
// parts. A ticked step becomes a Done task and an unticked one To do, under the label of the
// heading before it, so v24 makes the same steps when it runs again.
nonisolated enum ChecklistMigrationFixture {
    static func restoreTasks(in db: Database) throws {
        try db.create(table: "jobTask") { table in
            table.column("id", .text).primaryKey()
            table.column("jobID", .text).notNull().references("job", onDelete: .restrict)
            table.column("title", .text).notNull().check(sql: "length(trim(title)) > 0")
            for column in ["detail", "groupLabel", "waitingReason", "skippedReason"] {
                table.column(column, .text)
            }
            table.column("status", .text).notNull().check(
                sql: "status IN ('To do', 'Doing', 'Waiting', 'Done', 'Skipped')")
            table.check(
                sql:
                    "status != 'Skipped' OR (skippedReason IS NOT NULL AND length(trim(skippedReason)) > 0)"
            )
            table.column("createdAt", .double).notNull()
            table.column("updatedAt", .double).notNull()
            table.column("position", .integer).notNull().defaults(to: 0).check { $0 >= 0 }
        }
        try db.create(index: "jobTask_jobID", on: "jobTask", columns: ["jobID"])
        try db.create(
            index: "jobTask_jobID_position", on: "jobTask", columns: ["jobID", "position"])
        try db.create(table: "taskPart") { table in
            table.column("taskID", .text).notNull().references("jobTask", onDelete: .restrict)
            table.column("partID", .text).notNull().references(
                "partRequirement", onDelete: .restrict)
            table.primaryKey(["taskID", "partID"])
        }
        try db.create(index: "taskPart_partID", on: "taskPart", columns: ["partID"])
        var group: [UUID: String] = [:]
        var position: [UUID: Int] = [:]
        for step in try ChecklistQueries.fetchAll(db) {
            if step.isHeading {
                group[step.jobID] = step.text
                continue
            }
            try db.execute(
                sql: """
                    INSERT INTO jobTask (id, jobID, title, groupLabel, status, createdAt,
                        updatedAt, position)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    step.id.uuidString, step.jobID.uuidString, step.text, group[step.jobID],
                    step.isTicked ? "Done" : "To do", step.createdAt.timeIntervalSince1970,
                    step.updatedAt.timeIntervalSince1970, position[step.jobID, default: 0],
                ])
            position[step.jobID, default: 0] += 1
        }
        try db.drop(table: "checklistStep")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v24-checklist-steps'")
    }
}

// Puts a library back to the schema before v16, without links between tasks and parts.
nonisolated enum TaskPartMigrationFixture {
    static func removeLinks(in db: Database) throws {
        try SearchMigrationFixture.removeSearch(in: db)
        try db.drop(table: "taskPart")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v16-task-parts'")
        try db.execute(
            sql: """
                CREATE TABLE jobTask_old (
                    id TEXT PRIMARY KEY, jobID TEXT NOT NULL REFERENCES job(id) ON DELETE RESTRICT,
                    title TEXT NOT NULL CHECK(length(trim(title)) > 0),
                    detail TEXT, groupLabel TEXT, waitingReason TEXT, skippedReason TEXT,
                    status TEXT NOT NULL CHECK(status IN ('To do', 'Doing', 'Waiting', 'Done', 'Skipped')),
                    createdAt DOUBLE NOT NULL, updatedAt DOUBLE NOT NULL,
                    position INTEGER NOT NULL DEFAULT 0 CHECK(position >= 0),
                    CHECK(status != 'Waiting' OR (waitingReason IS NOT NULL AND length(trim(waitingReason)) > 0)),
                    CHECK(status != 'Skipped' OR (skippedReason IS NOT NULL AND length(trim(skippedReason)) > 0)))
                """)
        try db.execute(sql: "INSERT INTO jobTask_old SELECT * FROM jobTask")
        try db.drop(table: "jobTask")
        try db.rename(table: "jobTask_old", to: "jobTask")
        try db.create(index: "jobTask_jobID", on: "jobTask", columns: ["jobID"])
        try db.create(
            index: "jobTask_jobID_position", on: "jobTask", columns: ["jobID", "position"])
    }
}

// Puts a library back to the schema before v11, without tasks.
nonisolated enum JobTaskMigrationFixture {
    static func removeTasks(in db: Database) throws {
        try PartMigrationFixture.removeParts(in: db)
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v12-task-order'")
        try db.drop(table: "jobTask")
        try db.execute(sql: "ALTER TABLE job DROP COLUMN unfinishedTasksReason")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v11-job-tasks'")
        try db.execute(
            sql: """
                CREATE TABLE activityEvent_old (
                    id TEXT PRIMARY KEY, jobID TEXT NOT NULL REFERENCES job(id),
                    kind TEXT NOT NULL CHECK(kind IN ('Job stage changed', 'Watch condition changed')),
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

// A library and a backup package made by the schema before v24. Its jobs have tasks in groups
// that change and come back, a task with no group between them, all five statuses, details,
// waiting and skipped reasons, and links to the job's parts.
nonisolated enum LegacyChecklistFixture {
    private static let lastMigration = "v23-job-states"

    // A line of a checklist as a test compares it.
    struct Line: Equatable, CustomStringConvertible {
        let text: String
        var isHeading = false
        var isTicked = false

        init(_ text: String, isHeading: Bool = false, isTicked: Bool = false) {
            self.text = text
            self.isHeading = isHeading
            self.isTicked = isTicked
        }

        init(_ record: ChecklistStepRecord) {
            self.init(record.text, isHeading: record.isHeading, isTicked: record.isTicked)
        }

        var description: String {
            if isHeading { return "# \(text)" }
            return "[\(isTicked ? "x" : " ")] \(text)"
        }
    }

    struct Task {
        let id: UUID
        let title: String
        var group: String?
        let status: String
        var detail: String?
        var waitingReason: String?
        var skippedReason: String?
        let createdAt: Double
    }

    struct Part {
        let id: UUID
        let jobID: UUID
        let description: String
        var linkedTasks: [UUID] = []
    }

    struct Job {
        let id: UUID
        let watchID: UUID
        let title: String
        let stage: String
        var doneAt: Double?
        var notes = ""
        let tasks: [Task]
        let expectedLines: [Line]
        let expectedNotes: String
    }

    static let watchIDs = [id(0x01), id(0x02)]

    static let jobs = [
        Job(
            id: id(0x11), watchID: watchIDs[0], title: "Full service", stage: "In progress",
            notes: "Opened the case back.",
            tasks: [
                Task(
                    id: id(0x21), title: "Photograph dial, hands and movement",
                    group: "Disassembly", status: "Done", createdAt: 10),
                Task(
                    id: id(0x22), title: "Let down the mainspring", group: "Disassembly",
                    status: "Skipped", skippedReason: "Already let down", createdAt: 11),
                Task(
                    id: id(0x23), title: "Clean all parts", group: "Cleaning", status: "Doing",
                    detail: "Use the new rinse", createdAt: 12),
                Task(
                    id: id(0x24), title: "Check the crown and stem", status: "To do",
                    createdAt: 13),
                Task(
                    id: id(0x25), title: "Fit the new mainspring", group: "Assembly",
                    status: "Waiting", waitingReason: "Mainspring on order", createdAt: 14),
                Task(
                    id: id(0x26), title: "Oil and reassemble the movement", group: " Assembly ",
                    status: "To do", detail: "9010 on the pallets\nHP1300 on the barrel\n",
                    createdAt: 15),
                Task(
                    id: id(0x27), title: "Clean the case", group: "Cleaning", status: "Done",
                    detail: "  ", createdAt: 16),
                Task(
                    id: id(0x28), title: "Regulate on the timegrapher", group: "Cleaning",
                    status: "Waiting", detail: "Within +5 s/d",
                    waitingReason: "Timegrapher on loan", createdAt: 17),
            ],
            expectedLines: [
                Line("Disassembly", isHeading: true),
                Line("Photograph dial, hands and movement", isTicked: true),
                Line("Let down the mainspring", isTicked: true),
                Line("Cleaning", isHeading: true),
                Line("Clean all parts"),
                Line("Check the crown and stem"),
                Line("Assembly", isHeading: true),
                Line("Fit the new mainspring"),
                Line("Oil and reassemble the movement"),
                Line("Cleaning", isHeading: true),
                Line("Clean the case", isTicked: true),
                Line("Regulate on the timegrapher"),
            ],
            expectedNotes: "Opened the case back.\n\nFrom the old record\n\n"
                + "Step · Let down the mainspring\nSkipped reason: Already let down\n\n"
                + "Step · Clean all parts\nDetail: Use the new rinse\n\n"
                + "Step · Fit the new mainspring\nWaiting reason: Mainspring on order\n\n"
                + "Step · Oil and reassemble the movement\n"
                + "Detail: 9010 on the pallets\nHP1300 on the barrel\n\n"
                + "Step · Regulate on the timegrapher\nDetail: Within +5 s/d\n"
                + "Waiting reason: Timegrapher on loan"),
        Job(
            id: id(0x12), watchID: watchIDs[1], title: "New crystal", stage: "Done", doneAt: 2,
            notes: "From the old record\n\nOutcome: Fitted and sealed",
            tasks: [
                Task(id: id(0x31), title: "Fit the crystal", status: "Done", createdAt: 20),
                Task(
                    id: id(0x32), title: "Pressure test", status: "Skipped",
                    skippedReason: "No tester at the bench", createdAt: 21),
            ],
            expectedLines: [
                Line("Fit the crystal", isTicked: true), Line("Pressure test", isTicked: true),
            ],
            expectedNotes: "From the old record\n\nOutcome: Fitted and sealed\n\n"
                + "Step · Pressure test\nSkipped reason: No tester at the bench"),
    ]

    static let parts = [
        Part(id: id(0x41), jobID: jobs[0].id, description: "Mainspring", linkedTasks: [id(0x25)]),
        Part(
            id: id(0x42), jobID: jobs[0].id, description: "Crown",
            linkedTasks: [id(0x24), id(0x26)]),
    ]

    private static func id(_ last: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0x39, last))
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
                libraryID: manifest.libraryID, applicationVersion: "before W039",
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
            for (index, watchID) in watchIDs.enumerated() {
                try db.execute(
                    sql: "INSERT INTO watch (id, name, createdAt, updatedAt) VALUES (?, ?, 1, 2)",
                    arguments: [watchID.uuidString, "Watch \(index + 1)"])
            }
            for job in jobs {
                try db.execute(
                    sql: """
                        INSERT INTO job (id, watchID, title, stage, createdAt, updatedAt, doneAt,
                            notes)
                        VALUES (?, ?, ?, ?, 1, 3, ?, ?)
                        """,
                    arguments: [
                        job.id.uuidString, job.watchID.uuidString, job.title, job.stage,
                        job.doneAt, job.notes,
                    ])
                for (position, task) in job.tasks.enumerated() {
                    try db.execute(
                        sql: """
                            INSERT INTO jobTask (id, jobID, title, detail, groupLabel, status,
                                waitingReason, skippedReason, createdAt, updatedAt, position)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            task.id.uuidString, job.id.uuidString, task.title, task.detail,
                            task.group, task.status, task.waitingReason, task.skippedReason,
                            task.createdAt, task.createdAt + 1, position,
                        ])
                }
            }
            for part in parts {
                try db.execute(
                    sql: """
                        INSERT INTO partRequirement (id, jobID, description, quantity,
                            compatibility, status, createdAt, updatedAt)
                        VALUES (?, ?, ?, 1, 'Unchecked', 'Needed', 4, 4)
                        """,
                    arguments: [part.id.uuidString, part.jobID.uuidString, part.description])
                for task in part.linkedTasks {
                    try db.execute(
                        sql: "INSERT INTO taskPart (taskID, partID) VALUES (?, ?)",
                        arguments: [task.uuidString, part.id.uuidString])
                }
            }
            try SearchKey.backfill(
                "watch",
                fields: [
                    "name", "brand", "model", "caseReference", "serial", "approximateYear",
                    "owner", "contact", "notes",
                ], in: db)
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
