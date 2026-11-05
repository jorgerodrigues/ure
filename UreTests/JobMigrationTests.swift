import CryptoKit
import Foundation
import GRDB
import Testing

@testable import Ure

nonisolated struct JobMigrationTests {
    @Test
    func upgradeGivesEveryJobItsStateAndWritesRemovedValuesIntoNotes() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        try LegacyJobFixture.create(at: fixture.root)
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()

        let jobs = try await coordinator.read(JobQueries.fetchAll)
        #expect(jobs.count == LegacyJobFixture.jobs.count)
        let notes = RecordNotesService(coordinator: coordinator)
        for old in LegacyJobFixture.jobs {
            let job = try #require(jobs.first { $0.id == old.id })
            #expect(job.watchID == old.watchID && job.title == old.title)
            #expect(job.stage == old.expectedStage, "\(old.title)")
            #expect(job.problem == old.problem)
            #expect(job.waitingFor == old.expectedWaitingFor)
            #expect(job.doneAt?.timeIntervalSince1970 == old.expectedDoneAt, "\(old.title)")
            #expect(job.createdAt.timeIntervalSince1970 == old.createdAt)
            #expect(job.updatedAt.timeIntervalSince1970 == old.createdAt + 1)
            #expect(
                try await notes.text(for: .job(old.id)) == old.expectedNotes(), "\(old.title)")
        }
        let stored = try await coordinator.read { db in
            (
                columns: try db.columns(in: "job").map(\.name),
                tables: try String.fetchAll(
                    db, sql: "SELECT name FROM sqlite_schema WHERE type = 'table'"),
                tasks: try JobTaskRecord.fetchAll(db, sql: "SELECT * FROM jobTask"),
                parts: try PartRecord.fetchAll(db, sql: "SELECT * FROM partRequirement"),
                triggers: try String.fetchAll(
                    db, sql: "SELECT name FROM sqlite_schema WHERE type = 'trigger' ORDER BY name"),
                integrity: try String.fetchOne(db, sql: "PRAGMA integrity_check"),
                foreignKeys: try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
            )
        }
        #expect(
            stored.columns == [
                "id", "watchID", "title", "stage", "problem", "waitingFor", "createdAt",
                "updatedAt", "doneAt", "searchKey", "archivedAt", "notes",
            ])
        #expect(!stored.tables.contains("activityEvent"))
        #expect(stored.integrity == "ok" && stored.foreignKeys == 0)
        #expect(Set(stored.tasks.map(\.id)) == [LegacyJobFixture.taskID, LegacyJobFixture.skipped])
        #expect(
            stored.tasks.first { $0.id == LegacyJobFixture.skipped }?.skippedReason == "Not needed")
        #expect(stored.parts.map(\.id) == [LegacyJobFixture.partID])
        #expect(stored.parts.first?.statusReason == "Wrong size")
        #expect(stored.triggers == ["watch_cover_insert", "watch_cover_update"])
        // A removed value is found through the job's notes, and a waiting job through its title.
        #expect(
            try await coordinator.read { try SearchQueries.fetch("dial left as found", in: $0) }
                .map(\.recordID) == [LegacyJobFixture.jobs[4].id])
        #expect(
            try await coordinator.read { try SearchQueries.fetch("owner away", in: $0) }.map(
                \.recordID) == [LegacyJobFixture.jobs[5].id])
        // Every job still changes, and each watch keeps one open job.
        let service = JobService(coordinator: coordinator)
        _ = try await service.update(LegacyJobFixture.jobs[4].id, .title("Serviced"))
        await #expect(throws: JobError.self) {
            try await service.setStage(LegacyJobFixture.jobs[4].id, to: .inProgress)
        }
        try await coordinator.close()
    }

    @Test
    func backupMadeBeforeJobStatesRestoresWithTheRemovedValuesInNotes() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        _ = try await WatchService(coordinator: coordinator).create(named: "Replaced by restore")
        let package = fixture.directory.appending(path: "before-job-states.watchbackup")
        try LegacyJobFixture.package(at: package)
        let staged = try await coordinator.stageRestore(from: package)
        #expect(
            staged.summary.appliedMigrations == ["v23-job-states", "v24-jobs-without-watch"])
        #expect(staged.summary.counts["job"] == LegacyJobFixture.jobs.count)
        // The staged library is already upgraded, so its history is gone.
        #expect(staged.summary.counts["activityEvent"] == nil)
        let result = try await coordinator.activateRestore(staged)
        #expect(result.outcome == .restored)
        let restored = result.coordinator
        let jobs = try await restored.read(JobQueries.fetchAll)
        #expect(Set(jobs.map(\.id)) == Set(LegacyJobFixture.jobs.map(\.id)))
        let notes = RecordNotesService(coordinator: restored)
        for old in LegacyJobFixture.jobs {
            let job = jobs.first { $0.id == old.id }
            #expect(job?.stage == old.expectedStage && job?.waitingFor == old.expectedWaitingFor)
            #expect(try await notes.text(for: .job(old.id)) == old.expectedNotes())
        }
        try await restored.close()
    }

    @Test
    func eachJobWritesOnlyTheValuesThatGo() {
        #expect(
            JobMigration.entry(
                stage: "In progress", agreedScope: " ", intakeCondition: nil, intake: [],
                waitingReason: nil, outcome: "", recommendations: nil, cancellationReason: nil,
                unfinishedTasksReason: nil, unfinishedPartsReason: nil) == nil)
        #expect(
            JobMigration.entry(
                stage: "Waiting", agreedScope: nil, intakeCondition: nil, intake: [],
                waitingReason: "A crystal", outcome: nil, recommendations: nil,
                cancellationReason: nil, unfinishedTasksReason: nil, unfinishedPartsReason: nil)
                == nil)
        #expect(
            JobMigration.entry(
                stage: "Cancelled", agreedScope: "Full service\n", intakeCondition: "Stopped",
                intake: ["Serial at intake: 0012"], waitingReason: "Parts", outcome: "None",
                recommendations: "Keep dry", cancellationReason: nil,
                unfinishedTasksReason: "Left the dial", unfinishedPartsReason: "Crown on order")
                == "Agreed scope: Full service\nIntake condition: Stopped\n"
                + "Serial at intake: 0012\nWaiting reason: Parts\nOutcome: None\n"
                + "Recommendations: Keep dry\nCancelled\nUnfinished tasks: Left the dial\n"
                + "Unresolved parts: Crown on order")
        #expect(
            JobMigration.entry(
                stage: "Completed", agreedScope: nil, intakeCondition: nil, intake: [],
                waitingReason: nil, outcome: nil, recommendations: nil,
                cancellationReason: "Old reason", unfinishedTasksReason: nil,
                unfinishedPartsReason: nil) == "Cancellation reason: Old reason")
    }

    @Test
    func intakeValuesAreWrittenOnlyWhenTheWatchNoLongerHoldsThem() {
        let watch = IntakeWatch(
            name: "Seamaster", brand: "Omega", model: nil, caseReference: "2846",
            serial: "14 500 123", caliber: "552")
        let same =
            #"{"version":1,"watchName":"Seamaster ","brand":"Omega","caseReference":"2846","serial":"14 500 123","caliberDesignation":"552"}"#
        #expect(JobMigration.intake(same, watch: watch).isEmpty)
        let different =
            #"{"version":1,"watchName":"Seamaster 30","brand":"Omega","model":"CK 2846","serial":"0012","caliberDesignation":"30T2","caliberVariant":"RG"}"#
        #expect(
            JobMigration.intake(different, watch: watch) == [
                "Watch name at intake: Seamaster 30", "Model at intake: CK 2846",
                "Serial at intake: 0012", "Caliber at intake: 30T2",
                "Caliber variant at intake: RG",
            ])
        let future = #"{"version":2,"watchName":"Seamaster","futureEvidence":"keep"}"#
        #expect(JobMigration.intake(future, watch: watch) == ["Intake snapshot: \(future)"])
        #expect(JobMigration.intake("not json", watch: watch) == ["Intake snapshot: not json"])
    }

    @Test
    func historyKeepsOnlyReasonsThatNoRecordHolds() {
        var kept = KeptValues()
        let task = UUID()
        let part = UUID()
        kept.jobs["job"] = KeptValues.JobReasons(
            waitingReason: nil, outcome: "Serviced", recommendations: nil,
            cancellationReason: nil, unfinishedTasksReason: nil, unfinishedPartsReason: nil)
        kept.tasks[task] = KeptValues.TaskReasons(waitingReason: nil, skippedReason: "Not needed")
        kept.parts[part] = KeptValues.PartReasons(statusReason: "Wrong size", orderReference: nil)
        let stage =
            #"{"job":{"_0":{"stage":"Waiting","waitingReason":"The owner's answer","outcome":"Serviced"}}}"#
        #expect(
            JobHistory.reasons(in: stage, jobID: "job", kept: kept) == [
                "Waiting reason: The owner's answer"
            ])
        let taskValue =
            #"{"task":{"_0":{"taskID":"\#(task.uuidString)","title":"Clean","waitingReason":"Oil","skippedReason":"Not needed","status":"Waiting"}}}"#
        #expect(
            JobHistory.reasons(in: taskValue, jobID: "job", kept: kept) == [
                "Task · Clean · Waiting reason: Oil"
            ])
        let partValue =
            #"{"part":{"_0":{"partID":"\#(part.uuidString)","description":"Crown","quantity":1,"reason":"Wrong size","orderReference":"PO-1"}}}"#
        #expect(
            JobHistory.reasons(in: partValue, jobID: "job", kept: kept) == [
                "Part · Crown · Order reference: PO-1"
            ])
        let removedTask =
            #"{"task":{"_0":{"taskID":"\#(UUID().uuidString)","title":"Gone","skippedReason":"Not needed"}}}"#
        #expect(
            JobHistory.reasons(in: removedTask, jobID: "job", kept: kept) == [
                "Task · Gone · Skipped reason: Not needed"
            ])
        let condition = #"{"condition":{"_0":{"condition":"Stopped","note":" Dropped \n"}}}"#
        #expect(
            JobHistory.reasons(in: condition, jobID: "job", kept: kept) == [
                "Condition note:  Dropped"
            ])
        #expect(
            JobHistory.reasons(in: "{broken", jobID: "job", kept: kept) == [
                "History entry: {broken"
            ])
    }
}

// Puts a current library back to the schema before v23: six stages, the job fields v23 drops,
// and an empty activity history. Each job's intake snapshot copies its watch, so v23 writes
// nothing into the notes when it runs again.
nonisolated enum JobStateMigrationFixture {
    static func restoreJobFields(in db: Database) throws {
        try JobWatchMigrationFixture.requireWatch(in: db)
        // The job's tasks, parts and material wait for the rebuilt table, which takes the rows
        // back after the old one goes.
        try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
        try db.execute(
            sql: """
                CREATE TEMP TABLE job_copy AS
                SELECT job.id, job.watchID, job.title,
                    CASE job.stage WHEN 'Done' THEN 'Completed' ELSE job.stage END AS stage,
                    job.problem AS reportedProblem,
                    json_object(
                        'version', 1, 'watchName', watch.name, 'brand', watch.brand,
                        'model', watch.model, 'caseReference', watch.caseReference,
                        'serial', watch.serial,
                        'caliberDesignation',
                        (SELECT designation FROM caliber WHERE caliber.id = watch.caliberID)
                    ) AS intakeSnapshot,
                    job.createdAt, job.updatedAt, job.waitingFor AS waitingReason,
                    job.doneAt AS completedAt, job.searchKey, job.archivedAt, job.notes
                FROM job JOIN watch ON watch.id = job.watchID
                """)
        try db.execute(sql: "DROP TRIGGER watch_cover_insert")
        try db.execute(sql: "DROP TRIGGER watch_cover_update")
        try db.drop(table: "job")
        try db.execute(
            sql: """
                CREATE TABLE job (
                    id TEXT PRIMARY KEY,
                    watchID TEXT NOT NULL REFERENCES watch(id) ON DELETE RESTRICT,
                    title TEXT NOT NULL CHECK (length(trim(title)) > 0),
                    stage TEXT NOT NULL CHECK (stage IN ('Planned', 'In progress', 'Waiting', 'Ready', 'Completed', 'Cancelled')),
                    reportedProblem TEXT, agreedScope TEXT, intakeCondition TEXT,
                    intakeSnapshot TEXT NOT NULL CHECK (json_valid(intakeSnapshot)),
                    createdAt DOUBLE NOT NULL, updatedAt DOUBLE NOT NULL,
                    waitingReason TEXT, outcome TEXT, recommendations TEXT, cancellationReason TEXT,
                    startedAt DOUBLE, completedAt DOUBLE, cancelledAt DOUBLE,
                    unfinishedTasksReason TEXT, unfinishedPartsReason TEXT,
                    searchKey TEXT NOT NULL DEFAULT '', archivedAt DOUBLE,
                    notes TEXT NOT NULL DEFAULT '')
                """)
        try db.execute(
            sql: """
                INSERT INTO job
                    (id, watchID, title, stage, reportedProblem, intakeSnapshot, createdAt,
                     updatedAt, waitingReason, completedAt, searchKey, archivedAt, notes)
                SELECT id, watchID, title, stage, reportedProblem, intakeSnapshot, createdAt,
                    updatedAt, waitingReason, completedAt, searchKey, archivedAt, notes
                FROM job_copy
                """)
        try db.execute(sql: "DROP TABLE job_copy")
        try db.create(index: "job_watchID", on: "job", columns: ["watchID"])
        try db.execute(
            sql: """
                CREATE UNIQUE INDEX job_one_open_per_watch ON job(watchID)
                WHERE stage IN ('Planned', 'In progress', 'Waiting', 'Ready')
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
            sql: """
                CREATE TABLE activityEvent (
                    id TEXT PRIMARY KEY, jobID TEXT NOT NULL REFERENCES job(id) ON DELETE RESTRICT,
                    kind TEXT NOT NULL CHECK (kind IN ('Job stage changed', 'Watch condition changed', 'Task status changed', 'Part status changed')),
                    occurredAt DOUBLE NOT NULL, ordering INTEGER NOT NULL UNIQUE CHECK (ordering > 0),
                    priorValue TEXT NOT NULL CHECK (json_valid(priorValue)),
                    nextValue TEXT NOT NULL CHECK (json_valid(nextValue)))
                """)
        try db.create(
            index: "activityEvent_jobID_ordering", on: "activityEvent",
            columns: ["jobID", "ordering"])
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v23-job-states'")
    }
}

// A library and a backup package made by the schema before v23. It has a job in each of the
// six old stages with every job field that v23 removes, notes that already hold values from an
// older record, an intake snapshot this version can't read, and activity records with reasons
// that only the history holds.
nonisolated enum LegacyJobFixture {
    private static let lastMigration = "v22-watch-owner"

    struct Watch {
        let id: UUID
        let name: String
        var brand: String?
        var serial: String?
    }

    struct Job {
        let id: UUID
        let watchID: UUID
        let title: String
        let stage: String
        var problem: String?
        var agreedScope: String?
        var intakeCondition: String?
        var snapshot: String
        var waitingReason: String?
        var outcome: String?
        var recommendations: String?
        var cancellationReason: String?
        var startedAt: Double?
        var completedAt: Double?
        var cancelledAt: Double?
        var unfinishedTasksReason: String?
        var unfinishedPartsReason: String?
        var notes = ""
        let createdAt: Double
        let expectedStage: JobStage
        var expectedWaitingFor: String?
        var expectedDoneAt: Double?
        // The notes after v23, with the history lines dated in the Mac's own format.
        var expectedNotes: @Sendable () -> String = { "" }
    }

    struct Event {
        let jobID: UUID
        let kind: String
        let occurredAt: Double
        let prior: String
        let next: String
    }

    static let watches = [
        Watch(id: id(0x01), name: "Seamaster", brand: "Omega", serial: "14 500 123"),
        Watch(id: id(0x02), name: "Dress watch", brand: "Longines"),
        Watch(id: id(0x03), name: "Field watch"),
        Watch(id: id(0x04), name: "Pocket chronometer"),
    ]

    static let taskID = id(0x51)
    static let skipped = id(0x52)
    static let partID = id(0x61)
    // Noon on 14 October 2026 in UTC, so each history date is the same day in any time zone.
    private static let day = 1_791_979_200.0

    static let jobs = [
        Job(
            id: id(0x11), watchID: watches[0].id, title: "Full service", stage: "Planned",
            problem: "Loses about two minutes a day.", agreedScope: "Full service",
            intakeCondition: "Running, crown gritty",
            snapshot:
                #"{"version":1,"watchName":"Seamaster","brand":"Omega","serial":"14 500 123"}"#,
            createdAt: 10, expectedStage: .inProgress,
            expectedNotes: {
                "From the old record\n\nAgreed scope: Full service\n"
                    + "Intake condition: Running, crown gritty"
            }),
        Job(
            id: id(0x12), watchID: watches[1].id, title: "Mainspring", stage: "In progress",
            snapshot:
                #"{"version":1,"watchName":"Dress watch, 1962","brand":"Longines","serial":"0012"}"#,
            startedAt: 25, notes: "Opened the case back.", createdAt: 20,
            expectedStage: .inProgress,
            expectedNotes: {
                "Opened the case back.\n\nFrom the old record\n\n"
                    + "Watch name at intake: Dress watch, 1962\nSerial at intake: 0012\n\n"
                    + "History\n\(date(0)) · Waiting reason: Waiting for the owner's answer\n"
                    + "\(date(0)) · Condition note: Stopped after a knock\n"
                    + "\(date(1)) · Task · Clean the movement · Waiting reason: Mainspring on order\n"
                    + "\(date(2)) · Part · Mainspring · Order reference: PO-1"
            }),
        Job(
            id: id(0x13), watchID: watches[2].id, title: "Crystal", stage: "Waiting",
            snapshot: #"{"version":1,"watchName":"Field watch"}"#,
            waitingReason: "A crystal from Cousins", startedAt: 31, createdAt: 30,
            expectedStage: .waiting, expectedWaitingFor: "A crystal from Cousins"),
        Job(
            id: id(0x14), watchID: watches[3].id, title: "Regulate", stage: "Ready",
            snapshot: #"{"version":2,"watchName":"Pocket chronometer","futureEvidence":"keep"}"#,
            createdAt: 40, expectedStage: .inProgress,
            expectedNotes: {
                "From the old record\n\nIntake snapshot: "
                    + #"{"version":2,"watchName":"Pocket chronometer","futureEvidence":"keep"}"#
            }),
        Job(
            id: id(0x15), watchID: watches[0].id, title: "Earlier service", stage: "Completed",
            snapshot: #"{"version":1,"watchName":"Seamaster","brand":"Omega"}"#,
            outcome: "Serviced, +3 s/d", recommendations: "Replace the gaskets in 2028",
            startedAt: 2, completedAt: 5, unfinishedTasksReason: "Dial left as found",
            unfinishedPartsReason: "Crown back-ordered",
            notes: "From the old record\n\nPhoto · Dial", createdAt: 1, expectedStage: .done,
            expectedDoneAt: 5,
            expectedNotes: {
                "From the old record\n\nPhoto · Dial\n\nOutcome: Serviced, +3 s/d\n"
                    + "Recommendations: Replace the gaskets in 2028\n"
                    + "Unfinished tasks: Dial left as found\nUnresolved parts: Crown back-ordered"
            }),
        Job(
            id: id(0x16), watchID: watches[1].id, title: "Quote", stage: "Cancelled",
            snapshot: #"{"version":1,"watchName":"Dress watch","brand":"Longines"}"#,
            cancellationReason: "Owner declined the quote", cancelledAt: 8, createdAt: 6,
            expectedStage: .done, expectedDoneAt: 8,
            expectedNotes: {
                "From the old record\n\nCancelled: Owner declined the quote\n\n"
                    + "History\n\(date(0)) · Cancellation reason: Owner away"
            }),
    ]

    static let events = [
        Event(
            jobID: jobs[1].id, kind: "Job stage changed", occurredAt: day,
            prior: #"{"job":{"_0":{"stage":"Planned"}}}"#,
            next:
                #"{"job":{"_0":{"stage":"Waiting","waitingReason":"Waiting for the owner's answer"}}}"#
        ),
        Event(
            jobID: jobs[1].id, kind: "Watch condition changed", occurredAt: day,
            prior: #"{"condition":{"_0":{"condition":"Running"}}}"#,
            next: #"{"condition":{"_0":{"condition":"Stopped","note":"Stopped after a knock"}}}"#),
        Event(
            jobID: jobs[1].id, kind: "Job stage changed", occurredAt: day + 3_600,
            prior:
                #"{"job":{"_0":{"stage":"Waiting","waitingReason":"Waiting for the owner's answer"}}}"#,
            next: #"{"job":{"_0":{"stage":"In progress","startedAt":25}}}"#),
        Event(
            jobID: jobs[1].id, kind: "Task status changed", occurredAt: day + 86_400,
            prior:
                #"{"task":{"_0":{"taskID":"\#(taskID.uuidString)","title":"Clean the movement","status":"Waiting","waitingReason":"Mainspring on order"}}}"#,
            next:
                #"{"task":{"_0":{"taskID":"\#(taskID.uuidString)","title":"Clean the movement","status":"Doing"}}}"#
        ),
        Event(
            jobID: jobs[1].id, kind: "Task status changed", occurredAt: day + 86_400,
            prior:
                #"{"task":{"_0":{"taskID":"\#(skipped.uuidString)","title":"Polish","status":"To do"}}}"#,
            next:
                #"{"task":{"_0":{"taskID":"\#(skipped.uuidString)","title":"Polish","status":"Skipped","skippedReason":"Not needed"}}}"#
        ),
        Event(
            jobID: jobs[1].id, kind: "Part status changed", occurredAt: day + 2 * 86_400,
            prior:
                #"{"part":{"_0":{"partID":"\#(partID.uuidString)","description":"Mainspring","quantity":1,"status":"Needed"}}}"#,
            next:
                #"{"part":{"_0":{"partID":"\#(partID.uuidString)","description":"Mainspring","quantity":1,"status":"Ordered","orderReference":"PO-1"}}}"#
        ),
        Event(
            jobID: jobs[1].id, kind: "Part status changed", occurredAt: day + 2 * 86_400,
            prior:
                #"{"part":{"_0":{"partID":"\#(partID.uuidString)","description":"Mainspring","quantity":1,"status":"Ordered","orderReference":"PO-1"}}}"#,
            next:
                #"{"part":{"_0":{"partID":"\#(partID.uuidString)","description":"Mainspring","quantity":1,"status":"Needed","reason":"Wrong size"}}}"#
        ),
        Event(
            jobID: jobs[5].id, kind: "Job stage changed", occurredAt: day,
            prior: #"{"job":{"_0":{"stage":"Planned"}}}"#,
            next: #"{"job":{"_0":{"stage":"Cancelled","cancellationReason":"Owner away"}}}"#),
        Event(
            jobID: jobs[5].id, kind: "Job stage changed", occurredAt: day + 600,
            prior: #"{"job":{"_0":{"stage":"Cancelled","cancellationReason":"Owner away"}}}"#,
            next: #"{"job":{"_0":{"stage":"Planned"}}}"#),
        Event(
            jobID: jobs[5].id, kind: "Job stage changed", occurredAt: day + 1_200,
            prior: #"{"job":{"_0":{"stage":"Planned"}}}"#,
            next:
                #"{"job":{"_0":{"stage":"Cancelled","cancellationReason":"Owner declined the quote"}}}"#
        ),
    ]

    // A history date as v23 writes it, in the Mac's own region format.
    static func date(_ days: Int) -> String {
        var calendar = Locale.current.calendar
        calendar.timeZone = .current
        return Date(timeIntervalSince1970: day + Double(days) * 86_400).formatted(
            Date.FormatStyle(
                date: .long, time: .omitted, locale: .current, calendar: calendar,
                timeZone: .current))
    }

    private static func id(_ last: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0x37, last))
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
                libraryID: manifest.libraryID, applicationVersion: "before W037",
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
            for watch in watches {
                try db.execute(
                    sql: """
                        INSERT INTO watch (id, name, brand, serial, createdAt, updatedAt)
                        VALUES (?, ?, ?, ?, 1, 2)
                        """,
                    arguments: [watch.id.uuidString, watch.name, watch.brand, watch.serial])
            }
            for job in jobs { try insert(job, in: db) }
            try db.execute(
                sql: """
                    INSERT INTO jobTask (id, jobID, title, status, skippedReason, createdAt,
                        updatedAt, position)
                    VALUES (?, ?, 'Clean the movement', 'Doing', NULL, 21, 21, 0),
                        (?, ?, 'Polish', 'Skipped', 'Not needed', 21, 21, 1)
                    """,
                arguments: [
                    taskID.uuidString, jobs[1].id.uuidString, skipped.uuidString,
                    jobs[1].id.uuidString,
                ])
            try db.execute(
                sql: """
                    INSERT INTO partRequirement (id, jobID, description, quantity, compatibility,
                        status, statusReason, createdAt, updatedAt)
                    VALUES (?, ?, 'Mainspring', 1, 'Unchecked', 'Needed', 'Wrong size', 22, 22)
                    """, arguments: [partID.uuidString, jobs[1].id.uuidString])
            for (ordering, event) in events.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO activityEvent (id, jobID, kind, occurredAt, ordering,
                            priorValue, nextValue)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        UUID().uuidString, event.jobID.uuidString, event.kind, event.occurredAt,
                        ordering + 1, event.prior, event.next,
                    ])
            }
            try SearchKey.backfill(
                "watch",
                fields: [
                    "name", "brand", "model", "caseReference", "serial", "approximateYear",
                    "owner", "contact", "notes",
                ], in: db)
            try SearchKey.backfill("job", fields: ["title", "notes"], in: db)
        }
        try database.close()
        return manifest
    }

    private static func insert(_ job: Job, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO job (id, watchID, title, stage, reportedProblem, agreedScope,
                    intakeCondition, intakeSnapshot, createdAt, updatedAt, waitingReason, outcome,
                    recommendations, cancellationReason, startedAt, completedAt, cancelledAt,
                    unfinishedTasksReason, unfinishedPartsReason, notes)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                job.id.uuidString, job.watchID.uuidString, job.title, job.stage, job.problem,
                job.agreedScope, job.intakeCondition, job.snapshot, job.createdAt,
                job.createdAt + 1, job.waitingReason, job.outcome, job.recommendations,
                job.cancellationReason, job.startedAt, job.completedAt, job.cancelledAt,
                job.unfinishedTasksReason, job.unfinishedPartsReason, job.notes,
            ])
    }

    private static func fingerprint(_ file: URL, path: String) throws -> SnapshotFile {
        let bytes = try Data(contentsOf: file)
        return SnapshotFile(
            path: path, byteCount: Int64(bytes.count),
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
}
