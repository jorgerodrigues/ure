import CryptoKit
import Foundation
import GRDB
import Synchronization
import Testing

@testable import Ure

nonisolated struct RecordNotesMigrationTests {
    @Test
    func upgradeJoinsEveryNoteIntoItsRecordOldestFirst() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        try LegacyLibraryFixture.create(at: fixture.root)
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let notes = RecordNotesService(coordinator: coordinator)
        for (owner, text) in LegacyLibraryFixture.expectedNotes {
            #expect(try await notes.text(for: owner) == text)
        }
        let schema = try await coordinator.read { db in
            (
                hasNoteTable: try db.tableExists("note"),
                notesColumns: try ["watch", "caliber", "job"].map {
                    try db.columns(in: $0).contains { $0.name == "notes" }
                },
                watchUpdatedAt: try Double.fetchOne(
                    db, sql: "SELECT updatedAt FROM watch WHERE id = ?",
                    arguments: [LegacyLibraryFixture.watchID.uuidString])
            )
        }
        #expect(!schema.hasNoteTable && schema.notesColumns == [true, true, true])
        #expect(schema.watchUpdatedAt == 12)
        for (query, id) in [
            ("“J.R. 1958”", LegacyLibraryFixture.watchID),
            ("9010 on the pallet", LegacyLibraryFixture.caliberID),
            ("amplitude 238°", LegacyLibraryFixture.openJobID),
            ("replaced in 2021", LegacyLibraryFixture.closedJobID),
        ] {
            #expect(
                try await coordinator.read { try SearchQueries.fetch(query, in: $0) }.map(
                    \.recordID) == [id])
        }
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.root.appending(path: "recovery").path
            ).count == 1)
        try await coordinator.close()
        let reopened = fixture.coordinator()
        _ = try await reopened.open()
        for (owner, text) in LegacyLibraryFixture.expectedNotes {
            #expect(try await RecordNotesService(coordinator: reopened).text(for: owner) == text)
        }
        try await reopened.close()
    }

    @Test
    func backupMadeBeforeRecordNotesRestoresWithItsNotes() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        var draft = WatchDraft()
        draft.name = "Replaced by the restore"
        _ = try await WatchService(coordinator: coordinator).save(draft, editing: nil)
        let package = fixture.directory.appending(path: "before-notes.watchbackup")
        try LegacyLibraryFixture.package(at: package)
        let staged = try await coordinator.stageRestore(from: package)
        #expect(staged.summary.appliedMigrations == ["v19-record-notes"])
        #expect(staged.summary.counts["note"] == nil && staged.summary.counts["watch"] == 2)
        let result = try await coordinator.activateRestore(staged)
        #expect(result.outcome == .restored)
        let restored = RecordNotesService(coordinator: result.coordinator)
        for (owner, text) in LegacyLibraryFixture.expectedNotes {
            #expect(try await restored.text(for: owner) == text)
        }
        #expect(
            try await result.coordinator.read { try SearchQueries.fetch("“J.R. 1958”", in: $0) }
                .map(\.recordID) == [LegacyLibraryFixture.watchID])
        #expect(
            try await result.coordinator.read(WatchQueries.fetchAll).map(\.name).sorted()
                == ["Field watch", "Seamaster"])
        try await result.coordinator.close()
    }

    @Test
    func eachOldNoteStartsWithItsDateKindAndTitle() throws {
        let locale = Locale(identifier: "en_GB")
        let timeZone = try #require(TimeZone(identifier: "Europe/Lisbon"))
        let date = Date(timeIntervalSince1970: 1_791_979_200)
        #expect(
            NoteRecordsMigration.entry(
                title: "Mainspring", body: "  Set and weak.\n\nReplace it.\n \n", kind: "Work log",
                occurredAt: date, locale: locale, timeZone: timeZone)
                == "14 October 2026 · Work log · Mainspring\n  Set and weak.\n\nReplace it.")
        #expect(
            NoteRecordsMigration.entry(
                title: "Bracelet", body: "", kind: "Research", occurredAt: date, locale: locale,
                timeZone: timeZone) == "14 October 2026 · Research · Bracelet")
    }
}

nonisolated struct RecordNotesServiceTests {
    @Test
    func savingNotesChangesOnlyTheNotesTheEditTimeAndSearch() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = Mutex(Date(timeIntervalSince1970: 1_700_000_000))
        let coordinator = fixture.coordinator(
            dependencies: LibraryDependencies(now: { clock.withLock { $0 } }))
        _ = try await coordinator.open()
        let owners = try await NoteFixture.owners(coordinator)
        let service = RecordNotesService(coordinator: coordinator)
        let watch = try #require(try await coordinator.read(WatchQueries.fetchAll).first)
        let later = Date(timeIntervalSince1970: 1_700_000_100)
        clock.withLock { $0 = later }
        for (index, owner) in owners.enumerated() {
            #expect(try await service.text(for: owner).isEmpty)
            let text = "Mainspring set.\n  Å時計 0012-\(index)"
            try await service.save(text, for: owner)
            #expect(try await service.text(for: owner) == text)
            let results = try await coordinator.read {
                try SearchQueries.fetch("å時計 0012-\(index)", in: $0)
            }
            #expect(results.count == 1)
        }
        var expected = watch
        expected.updatedAt = later
        #expect(try await coordinator.read { try WatchQueries.fetch(watch.id, in: $0) } == expected)
        try await service.save("", for: owners[0])
        #expect(try await coordinator.read { try SearchQueries.fetch("0012-0", in: $0) }.isEmpty)
        try await coordinator.close()
    }

    @Test
    func closedArchivedAndMissingRecordsRejectNotes() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owners = try await NoteFixture.owners(coordinator)
        guard case .job(let jobID) = owners[1], case .caliber(let caliberID) = owners[2] else {
            throw NoteFixtureError()
        }
        let service = RecordNotesService(coordinator: coordinator)
        var closure = JobTransitionDraft(stage: .cancelled)
        closure.cancellationReason = "Customer collected the watch"
        _ = try await JobService(coordinator: coordinator).transition(jobID, using: closure)
        await #expect(throws: JobError.closedJob) {
            try await service.save("Too late", for: .job(jobID))
        }
        _ = try await ArchiveService(coordinator: coordinator).setCaliber(
            caliberID, archived: true)
        await #expect(throws: ArchiveError.archived) {
            try await service.save("Archived", for: .caliber(caliberID))
        }
        await #expect(throws: ArchiveError.missingRecord) {
            try await service.save("Nowhere", for: .watch(UUID()))
        }
        await #expect(throws: ArchiveError.missingRecord) {
            _ = try await service.text(for: .watch(UUID()))
        }
        #expect(try await service.text(for: .job(jobID)).isEmpty)
        #expect(try await service.text(for: .caliber(caliberID)).isEmpty)
        try await coordinator.close()
    }
}

struct AutosaveFieldTests {
    @Test(.timeLimit(.minutes(1)))
    func typingSavesHalfASecondAfterTheLastChange() async throws {
        let gate = PauseGate()
        let store = SavedTexts()
        let field = AutosaveField(
            text: "", actionName: "Notes", save: store.save, pause: gate.pause)
        field.beginEditing()
        field.change(to: "M", undoManager: nil)
        field.change(to: "Ma", undoManager: nil)
        field.change(to: "Mainspring", undoManager: nil)
        try await waitUntil { gate.requests.count == 3 && gate.waiting == 1 }
        #expect(gate.requests.allSatisfy { $0 == .milliseconds(500) })
        #expect(store.texts.isEmpty && field.hasUnsavedChanges)
        try await gate.elapse()
        try await waitUntil { field.savedText == "Mainspring" }
        #expect(store.texts == ["Mainspring"] && !field.hasUnsavedChanges && field.isEditing)
    }

    @Test(.timeLimit(.minutes(1)))
    func leavingTheFieldSavesAtOnce() async throws {
        let gate = PauseGate()
        let store = SavedTexts()
        let field = AutosaveField(
            text: "", actionName: "Notes", save: store.save, pause: gate.pause)
        field.beginEditing()
        field.change(to: "Bench note", undoManager: nil)
        field.endEditing()
        try await waitUntil { field.savedText == "Bench note" }
        #expect(await field.flush())
        #expect(store.texts == ["Bench note"] && !field.isEditing)
    }

    @Test(.timeLimit(.minutes(1)))
    func undoAndRedoChangeTheSavedText() async throws {
        let gate = PauseGate()
        let store = SavedTexts()
        let field = AutosaveField(
            text: "", actionName: "Notes", save: store.save, pause: gate.pause)
        let undo = UndoManager()
        undo.groupsByEvent = false
        field.beginEditing()
        undo.beginUndoGrouping()
        field.change(to: "First", undoManager: undo)
        field.change(to: "First line", undoManager: undo)
        undo.endUndoGrouping()
        try await gate.elapse()
        try await waitUntil { field.savedText == "First line" }
        undo.beginUndoGrouping()
        field.change(to: "First line\nSecond", undoManager: undo)
        undo.endUndoGrouping()
        try await gate.elapse()
        try await waitUntil { field.savedText == "First line\nSecond" }
        #expect(undo.undoActionName == "Notes")
        undo.undo()
        #expect(field.text == "First line")
        try await waitUntil { field.savedText == "First line" }
        undo.undo()
        #expect(field.text == "" && !undo.canUndo)
        try await waitUntil { field.savedText.isEmpty }
        undo.redo()
        #expect(field.text == "First line" && undo.canRedo)
        try await waitUntil { field.savedText == "First line" }
        #expect(
            store.texts == ["First line", "First line\nSecond", "First line", "", "First line"])
    }

    @Test(.timeLimit(.minutes(1)))
    func escapePutsBackTheTextFromWhenEditingBeganEvenAfterASave() async throws {
        let gate = PauseGate()
        let store = SavedTexts()
        let field = AutosaveField(
            text: "Saved", actionName: "Notes", save: store.save, pause: gate.pause)
        field.revert(undoManager: nil)
        #expect(field.text == "Saved")
        field.beginEditing()
        field.change(to: "Saved and typed", undoManager: nil)
        try await gate.elapse()
        try await waitUntil { field.savedText == "Saved and typed" }
        field.revert(undoManager: nil)
        #expect(field.text == "Saved")
        try await waitUntil { field.savedText == "Saved" }
        #expect(store.texts == ["Saved and typed", "Saved"])
    }

    @Test(.timeLimit(.minutes(1)))
    func failedSaveKeepsTheTextAndSavesOnRetry() async throws {
        let gate = PauseGate()
        let store = SavedTexts()
        store.failure = ArchiveError.archived
        let field = AutosaveField(
            text: "", actionName: "Notes", save: store.save, pause: gate.pause)
        field.beginEditing()
        field.change(to: "Keep me", undoManager: nil)
        field.endEditing()
        try await waitUntil { field.saveError != nil }
        #expect(field.text == "Keep me" && field.savedText.isEmpty && field.hasUnsavedChanges)
        #expect(field.saveError == ArchiveError.archived.localizedDescription)
        #expect(await !field.flush())
        field.refresh("Stored elsewhere")
        #expect(field.text == "Keep me")
        store.failure = nil
        #expect(await field.flush())
        #expect(
            field.saveError == nil && field.savedText == "Keep me" && store.texts == ["Keep me"])
    }
}

struct RecordNotesStateTests {
    @Test(.timeLimit(.minutes(1)))
    func notesSaveBeforeQuittingAndWhenNavigatingWithoutTheDraftQuestion() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owners = try await NoteFixture.owners(coordinator)
        let gate = PauseGate()
        let service = RecordNotesService(coordinator: coordinator)
        let notes = RecordNotesState(service: service, pause: gate.pause)
        await notes.load(owners[0])
        let watchNotes = try #require(notes.field(for: owners[0]))
        #expect(watchNotes.text.isEmpty && !notes.hasUnsavedChanges)
        watchNotes.beginEditing()
        watchNotes.change(to: "Typed before quitting", undoManager: nil)
        #expect(notes.hasUnsavedChanges && notes.isEditing)
        #expect(await notes.saveAll())
        #expect(try await service.text(for: owners[0]) == "Typed before quitting")
        #expect(!notes.hasUnsavedChanges)
        let editing = WorkshopEditing(
            watches: WatchState(service: WatchService(coordinator: coordinator)),
            calibers: CaliberState(service: CaliberService(coordinator: coordinator)),
            jobs: JobState(service: JobService(coordinator: coordinator)), notes: notes,
            references: ReferenceState(service: ReferenceService(coordinator: coordinator)),
            photos: PhotoState(service: PhotoService(coordinator: coordinator)),
            documents: DocumentState(service: DocumentService(coordinator: coordinator)),
            tasks: JobTaskState(service: JobTaskService(coordinator: coordinator)),
            parts: PartState(service: PartService(coordinator: coordinator)))
        await notes.load(owners[1])
        let jobNotes = try #require(notes.field(for: owners[1]))
        jobNotes.change(to: "Typed before leaving", undoManager: nil)
        var navigated = false
        editing.requestNavigation { navigated = true }
        #expect(navigated && !editing.showsUnsavedChanges && !editing.hasUnsavedChanges)
        try await waitUntil { !notes.hasUnsavedChanges }
        #expect(try await service.text(for: owners[1]) == "Typed before leaving")
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func failedSaveKeepsTypedNotesOnScreenUntilTheyCanSave() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owners = try await NoteFixture.owners(coordinator)
        guard case .caliber(let caliberID) = owners[2] else { throw NoteFixtureError() }
        let service = RecordNotesService(coordinator: coordinator)
        let notes = RecordNotesState(service: service, pause: PauseGate().pause)
        await notes.load(owners[2])
        let field = try #require(notes.field(for: owners[2]))
        field.beginEditing()
        field.change(to: "Lift angle 52°", undoManager: nil)
        let archive = ArchiveService(coordinator: coordinator)
        _ = try await archive.setCaliber(caliberID, archived: true)
        #expect(await !notes.saveAll())
        #expect(field.text == "Lift angle 52°" && notes.hasUnsavedChanges)
        #expect(field.saveError == ArchiveError.archived.localizedDescription)
        await notes.load(owners[2])
        #expect(notes.field(for: owners[2])?.text == "Lift angle 52°")
        _ = try await archive.setCaliber(caliberID, archived: false)
        #expect(await notes.saveAll())
        #expect(field.saveError == nil && !notes.hasUnsavedChanges)
        #expect(try await service.text(for: owners[2]) == "Lift angle 52°")
        await notes.load(.watch(UUID()))
        #expect(notes.loadErrors.count == 1)
        try await coordinator.close()
    }
}

private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw AutosaveTimeout()
}

nonisolated private struct AutosaveTimeout: Error {}

// Holds each pause until the test lets the time pass. A cancelled pause throws, like Task.sleep.
private final class PauseGate {
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private(set) var requests: [Duration] = []
    var waiting: Int { waiters.count }

    func pause(_ duration: Duration) async throws {
        requests.append(duration)
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    func elapse() async throws {
        try await waitUntil { !waiters.isEmpty }
        let current = waiters
        waiters = [:]
        for continuation in current.values { continuation.resume() }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private final class SavedTexts {
    private(set) var texts: [String] = []
    var failure: (any Error)?

    func save(_ text: String) async throws {
        if let failure { throw failure }
        texts.append(text)
    }
}

nonisolated enum NoteFixture {
    static func owners(_ coordinator: LibraryCoordinator) async throws -> [LibraryItemOwner] {
        var caliberDraft = CaliberDraft()
        caliberDraft.designation = "0012–Å"
        let caliber = try await CaliberService(coordinator: coordinator).save(
            caliberDraft, editing: nil)
        var watchDraft = WatchDraft()
        watchDraft.name = "Bench watch"
        watchDraft.caliberID = caliber.id
        let watch = try await WatchService(coordinator: coordinator).save(watchDraft, editing: nil)
        var jobDraft = JobDraft()
        jobDraft.title = "Inspect movement"
        let job = try await JobService(coordinator: coordinator).save(
            jobDraft, for: watch.id, editing: nil)
        return [.watch(watch.id), .job(job.id), .caliber(caliber.id)]
    }
}

nonisolated struct NoteFixtureError: Error {}

nonisolated enum NoteMigrationFixture {
    static func removeNotes(in db: Database) throws {
        try ReferenceMigrationFixture.removeLinks(in: db)
        try db.execute(sql: "DROP TABLE note")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v6-notes'")
    }
}

// Puts a current library back to the schema before v19, keeping each notes text as a note.
nonisolated enum RecordNotesMigrationFixture {
    static func restoreNoteRecords(in db: Database) throws {
        try db.create(table: "note") { table in
            table.column("id", .text).primaryKey()
            table.column("watchID", .text).references("watch", onDelete: .restrict)
            table.column("jobID", .text).references("job", onDelete: .restrict)
            table.column("caliberID", .text).references("caliber", onDelete: .restrict)
            table.check(
                sql: "(watchID IS NOT NULL) + (jobID IS NOT NULL) + (caliberID IS NOT NULL) = 1")
            table.column("title", .text).notNull().check(sql: "length(trim(title)) > 0")
            table.column("body", .text).notNull()
            table.column("kind", .text).notNull()
                .check(sql: "kind IN ('Observation', 'Research', 'Work log', 'Measurement')")
            for column in ["occurredAt", "createdAt", "updatedAt"] {
                table.column(column, .double).notNull()
            }
            table.column("searchKey", .text).notNull().defaults(to: "")
        }
        for owner in ["watchID", "jobID", "caliberID"] {
            try db.create(
                index: "note_\(owner)_occurredAt", on: "note", columns: [owner, "occurredAt"])
        }
        try db.create(index: "note_searchKey", on: "note", columns: ["searchKey"])
        let searchFields = [
            "watch": ["name", "brand", "model", "caseReference", "serial", "approximateYear"],
            "caliber": ["designation", "manufacturer", "variant"],
            "job": ["title"],
        ]
        for (table, fields) in searchFields {
            for row in try Row.fetchAll(
                db, sql: "SELECT id, notes, updatedAt FROM \(table) WHERE notes != ''")
            {
                let updatedAt: Double = row["updatedAt"]
                try db.execute(
                    sql: """
                        INSERT INTO note (id, \(table)ID, title, body, kind, occurredAt, createdAt,
                            updatedAt)
                        VALUES (?, ?, 'Notes', ?, 'Observation', ?, ?, ?)
                        """,
                    arguments: [
                        UUID().uuidString, row["id"], row["notes"], updatedAt, updatedAt,
                        updatedAt,
                    ])
            }
            try db.execute(sql: "ALTER TABLE \(table) DROP COLUMN notes")
            try SearchKey.backfill(table, fields: fields, in: db)
        }
        try SearchKey.backfill("note", fields: ["title", "body"], in: db)
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v19-record-notes'")
    }
}

// A library and a backup package made by the schema before v19, with notes of every kind and
// scope, an empty body and a long body.
nonisolated enum LegacyLibraryFixture {
    static let caliberID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 0x01))
    static let watchID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 0x02))
    static let quietWatchID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 0x03))
    static let openJobID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 0x04))
    static let closedJobID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 0x05))
    private static let lastMigration = "v18-plain-part-links"
    private static let longBody = String(
        repeating: "+132 s/d · amplitude 238° · beat error 0.4 ms · Ühren\n", count: 2_000)

    private struct Note {
        let owner: LibraryItemOwner
        let title: String
        let body: String
        let kind: String
        let occurredAt: Double
        let createdAt: Double
    }

    private static let notes = [
        Note(
            owner: .watch(watchID), title: "Caseback engraving",
            body: "The caseback is engraved “J.R. 1958”.", kind: "Observation",
            occurredAt: 1_791_806_400, createdAt: 30),
        Note(
            owner: .watch(watchID), title: "Bracelet", body: "", kind: "Research",
            occurredAt: 1_791_633_600, createdAt: 20),
        Note(
            owner: .job(openJobID), title: "Mainspring",
            body: "Set and weak.\n  Old oil on the escape wheel.\n\n", kind: "Work log",
            occurredAt: 1_791_979_200, createdAt: 50),
        Note(
            owner: .job(openJobID), title: "Timegrapher", body: longBody, kind: "Measurement",
            occurredAt: 1_791_979_200, createdAt: 40),
        Note(
            owner: .caliber(caliberID), title: "Service guide",
            body: "Use 9010 on the pallet stones.", kind: "Research", occurredAt: 1_790_856_000,
            createdAt: 10),
        Note(
            owner: .job(closedJobID), title: "Old crystal", body: "Replaced in 2021.",
            kind: "Observation", occurredAt: 1_614_686_400, createdAt: 5),
    ]

    static var expectedNotes: [(LibraryItemOwner, String)] {
        func entry(_ note: Note) -> String {
            NoteRecordsMigration.entry(
                title: note.title, body: note.body, kind: note.kind,
                occurredAt: Date(timeIntervalSince1970: note.occurredAt), locale: .current,
                timeZone: .current)
        }
        func day(_ seconds: Double) -> String {
            Date(timeIntervalSince1970: seconds).formatted(date: .long, time: .omitted)
        }
        return [
            (
                .watch(watchID),
                "\(day(1_791_633_600)) · Research · Bracelet\n\n"
                    + "\(day(1_791_806_400)) · Observation · Caseback engraving\n"
                    + "The caseback is engraved “J.R. 1958”."
            ),
            (
                .job(openJobID),
                "\(day(1_791_979_200)) · Measurement · Timegrapher\n"
                    + String(longBody.dropLast()) + "\n\n"
                    + "\(day(1_791_979_200)) · Work log · Mainspring\n"
                    + "Set and weak.\n  Old oil on the escape wheel."
            ),
            (.job(closedJobID), entry(notes[5])),
            (.caliber(caliberID), entry(notes[4])),
            (.watch(quietWatchID), ""),
        ]
    }

    static func create(at root: URL) throws {
        let generationID = UUID()
        let generation = LibraryFiles.generation(generationID, in: root)
        try FileManager.default.createDirectory(
            at: LibraryFiles.originals(in: generation), withIntermediateDirectories: true)
        try database(in: generation)
        try LibraryFiles.write(
            ActiveLibrary(
                formatVersion: LibraryManifest.currentVersion, generationID: generationID),
            to: root.appending(path: "active-library.json"))
    }

    static func package(at package: URL) throws {
        try FileManager.default.createDirectory(
            at: LibraryFiles.originals(in: package), withIntermediateDirectories: true)
        let library = try database(in: package)
        let reader = try DatabaseQueue(path: LibraryFiles.database(in: package).path)
        let counts = try reader.read(BackupQueries.counts)
        try reader.close()
        let migrations = LibrarySchema.migrator.migrations
        let lastIndex = try #require(migrations.firstIndex(of: lastMigration))
        try LibraryFiles.write(
            BackupManifest(
                formatVersion: BackupManifest.currentVersion,
                exportedAt: Date(timeIntervalSince1970: 1_792_000_000),
                libraryID: library.libraryID, applicationVersion: "before W033",
                migrations: Array(migrations[...lastIndex]), counts: counts,
                files: try ["library.sqlite", "manifest.json"].map {
                    try fingerprint(package.appending(path: $0), path: $0)
                }),
            to: package.appending(path: "backup.json"))
    }

    @discardableResult
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
            try seed(db)
        }
        try database.close()
        return manifest
    }

    private static func seed(_ db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO caliber (id, designation, manufacturer, movementType, createdAt, updatedAt)
                VALUES (?, '552', 'Omega', 'Automatic', 10, 11)
                """, arguments: [caliberID.uuidString])
        try db.execute(
            sql: """
                INSERT INTO watch (id, name, brand, caliberID, createdAt, updatedAt)
                VALUES (?, 'Seamaster', 'Omega', ?, 10, 12), (?, 'Field watch', NULL, NULL, 10, 13)
                """,
            arguments: [watchID.uuidString, caliberID.uuidString, quietWatchID.uuidString])
        let snapshot = try String(
            decoding: JSONEncoder().encode(
                JobIntakeSnapshot(
                    watchName: "Seamaster", brand: "Omega", model: nil, caseReference: nil,
                    serial: nil, caliberDesignation: "552", caliberVariant: nil)), as: UTF8.self)
        try db.execute(
            sql: """
                INSERT INTO job (id, watchID, title, stage, intakeSnapshot, createdAt, updatedAt)
                VALUES (?, ?, 'Full service', 'In progress', ?, 20, 21),
                    (?, ?, 'New crystal', 'Completed', ?, 5, 6)
                """,
            arguments: [
                openJobID.uuidString, watchID.uuidString, snapshot, closedJobID.uuidString,
                watchID.uuidString, snapshot,
            ])
        for note in notes {
            let column: String
            let ownerID: UUID
            switch note.owner {
            case .watch(let id): (column, ownerID) = ("watchID", id)
            case .job(let id): (column, ownerID) = ("jobID", id)
            case .caliber(let id): (column, ownerID) = ("caliberID", id)
            }
            try db.execute(
                sql: """
                    INSERT INTO note (id, \(column), title, body, kind, occurredAt, createdAt,
                        updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString, ownerID.uuidString, note.title, note.body, note.kind,
                    note.occurredAt, note.createdAt, note.createdAt,
                ])
        }
        try SearchKey.backfill("note", fields: ["title", "body"], in: db)
    }

    private static func fingerprint(_ file: URL, path: String) throws -> SnapshotFile {
        let bytes = try Data(contentsOf: file)
        return SnapshotFile(
            path: path, byteCount: Int64(bytes.count),
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
}
