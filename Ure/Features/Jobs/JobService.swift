import Foundation
import GRDB

nonisolated enum JobError: LocalizedError, Equatable {
    case unavailableWatch
    case missingRecord
    case notWaiting
    case openJobExists(JobRecord)

    var errorDescription: String? {
        switch self {
        case .unavailableWatch: "This watch is no longer available."
        case .missingRecord: "This job is no longer available."
        case .notWaiting: "Set the job to Waiting to say what it waits for."
        case .openJobExists:
            "This watch already has an open job. Open that job to continue its repair."
        }
    }
}

nonisolated struct JobValidationError: LocalizedError, Equatable {
    let message: String

    var errorDescription: String? { message }
}

// One fact on a job page. Each saves on its own, so two fields never overwrite each other.
nonisolated enum JobFact: Equatable, Sendable {
    case title(String)
    case problem(String)
    case waitingFor(String)
}

// A job's state with the values that belong to it: what a waiting job waits for, and when a
// done job was done. Undo puts back exactly these.
nonisolated struct JobStageValue: Equatable, Sendable {
    let stage: JobStage
    var waitingFor: String? = nil
    var doneAt: Date? = nil

    init(stage: JobStage, waitingFor: String? = nil, doneAt: Date? = nil) {
        self.stage = stage
        self.waitingFor = waitingFor
        self.doneAt = doneAt
    }

    init(job: JobRecord) {
        stage = job.stage
        waitingFor = job.waitingFor
        doneAt = job.doneAt
    }
}

// A state change: the job as it was saved, and the state it had before.
nonisolated struct JobStageChange: Equatable, Sendable {
    let prior: JobStageValue
    let job: JobRecord
}

nonisolated struct JobService: Sendable {
    static let newTitle = "New Job"

    let coordinator: LibraryCoordinator

    // Opens a job In progress. A job can start without a watch while you set it up. A watch
    // must not be archived and must have no open job.
    func start(for watchID: UUID?, title: String = newTitle) async throws -> JobRecord {
        try await coordinator.mutate { db, _, dependencies in
            if let watchID { try Self.requireWatchForOpenJob(watchID, in: db) }
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            var record = JobRecord(
                id: dependencies.makeID(), watchID: watchID, title: Self.newTitle,
                stage: .inProgress, createdAt: now, updatedAt: now)
            try record.apply(.title(title))
            try JobQueries.insert(record, in: db)
            return record
        }
    }

    // Gives a job its watch, or takes it away again when Undo puts back "No watch yet". An open
    // job needs a watch that is not archived and has no other open job. When the watch goes,
    // a cover the watch took from this job's photos goes too, so the watch never shows a photo
    // that is no longer its own.
    func setWatch(_ id: UUID, to watchID: UUID?) async throws -> JobRecord {
        try await coordinator.mutate { db, _, dependencies in
            try Self.setWatch(id, to: watchID, at: dependencies.now(), in: db)
        }
    }

    // Makes a watch with the name you typed in the picker and gives it to the job, in one go.
    func setNewWatch(_ id: UUID, named name: String) async throws -> JobRecord {
        try await coordinator.mutate { db, _, dependencies in
            _ = try Self.requireJob(id, in: db)
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let watch = WatchRecord(
                id: dependencies.makeID(), name: trimmed.isEmpty ? WatchService.newName : trimmed,
                createdAt: now, updatedAt: now)
            try WatchQueries.insert(watch, in: db)
            return try Self.setWatch(id, to: watch.id, at: now, in: db)
        }
    }

    // Removes a job that has nothing in it yet: no watch, the title it started with, and no
    // problem, notes, checklist steps, parts or material. Anything else stays. True when it went.
    func discardIfBlank(_ id: UUID) async throws -> Bool {
        try await coordinator.mutate { db, _, _ in
            guard let job = try JobQueries.fetch(id, in: db), job.watchID == nil,
                job.title == Self.newTitle, job.problem == nil, job.waitingFor == nil,
                (try RecordNotesQueries.fetch(.job(id), in: db) ?? "").isEmpty
            else { return false }
            for table in ["checklistStep", "partRequirement", "libraryItem"] {
                let count =
                    try Int.fetchOne(
                        db, sql: "SELECT count(*) FROM \(table) WHERE jobID = ?",
                        arguments: [id.uuidString]) ?? 0
                guard count == 0 else { return false }
            }
            try db.execute(sql: "DELETE FROM job WHERE id = ?", arguments: [id.uuidString])
            return db.changesCount == 1
        }
    }

    // Saves one fact. A value that is already saved changes nothing, not even the edit time. A
    // Done job takes changes like any other.
    func update(_ id: UUID, _ fact: JobFact) async throws -> JobRecord {
        try await coordinator.mutate { db, _, dependencies in
            var record = try Self.requireJob(id, in: db)
            let saved = record
            try record.apply(fact)
            guard record != saved else { return saved }
            record.updatedAt = Date(
                timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            try JobQueries.update(record, in: db)
            return record
        }
    }

    // Moves a job to another state. Done records when the job was done, and leaving Done clears
    // that date. Leaving Waiting clears what the job waited for. A job that leaves Done needs its
    // watch to have no other open job.
    func setStage(_ id: UUID, to stage: JobStage) async throws -> JobStageChange {
        try await coordinator.mutate { db, _, dependencies in
            let existing = try Self.requireJob(id, in: db)
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            guard existing.stage != stage else {
                return JobStageChange(prior: JobStageValue(job: existing), job: existing)
            }
            var next = JobStageValue(stage: stage)
            if stage == .done { next.doneAt = now }
            let job = try Self.write(next, to: existing, at: now, in: db)
            return JobStageChange(prior: JobStageValue(job: existing), job: job)
        }
    }

    // Puts back a state as it was, with its waiting text and done date. Undo and Redo use it.
    func restoreStage(_ id: UUID, to value: JobStageValue) async throws -> JobRecord {
        try await coordinator.mutate { db, _, dependencies in
            let existing = try Self.requireJob(id, in: db)
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            return try Self.write(value, to: existing, at: now, in: db)
        }
    }

    // A job can change while it is in the library and not archived. That holds when it is
    // Done, when its watch is archived, and while it has no watch yet.
    static func requireJob(_ id: UUID, in db: Database) throws -> JobRecord {
        guard let job = try JobQueries.fetch(id, in: db) else { throw JobError.missingRecord }
        guard job.archivedAt == nil else { throw ArchiveError.archived }
        return job
    }

    // A watch that can take a new open job: in the library, not archived, and with no open job.
    private static func requireWatchForOpenJob(
        _ watchID: UUID, except jobID: UUID? = nil, in db: Database
    ) throws {
        guard try WatchQueries.fetch(watchID, in: db) != nil else {
            throw JobError.unavailableWatch
        }
        try RecordAccess.requireWatch(watchID, in: db)
        if let existing = try JobQueries.openJob(for: watchID, in: db), existing.id != jobID {
            throw JobError.openJobExists(existing)
        }
    }

    private static func setWatch(
        _ id: UUID, to watchID: UUID?, at time: Date, in db: Database
    ) throws -> JobRecord {
        var job = try requireJob(id, in: db)
        guard job.watchID != watchID else { return job }
        if let watchID {
            guard try WatchQueries.fetch(watchID, in: db) != nil else {
                throw JobError.unavailableWatch
            }
            try RecordAccess.requireWatch(watchID, in: db)
            if job.stage.isOpen { try requireWatchForOpenJob(watchID, except: id, in: db) }
        }
        if let previous = job.watchID {
            try db.execute(
                sql: """
                    UPDATE watch SET coverPhotoID = NULL
                    WHERE id = ? AND coverPhotoID IN (SELECT id FROM libraryItem WHERE jobID = ?)
                    """, arguments: [previous.uuidString, id.uuidString])
        }
        job.watchID = watchID
        job.updatedAt = Date(timeIntervalSince1970: time.timeIntervalSince1970)
        try JobQueries.update(job, in: db)
        return job
    }

    private static func write(
        _ value: JobStageValue, to existing: JobRecord, at now: Date, in db: Database
    ) throws -> JobRecord {
        guard JobStageValue(job: existing) != value else { return existing }
        if value.stage.isOpen, !existing.stage.isOpen, let watchID = existing.watchID,
            let open = try JobQueries.openJob(for: watchID, in: db)
        {
            throw JobError.openJobExists(open)
        }
        var job = existing
        job.stage = value.stage
        job.waitingFor = nil
        job.doneAt = nil
        if value.stage == .waiting { job.waitingFor = value.waitingFor }
        if value.stage == .done { job.doneAt = value.doneAt ?? now }
        job.updatedAt = now
        try JobQueries.update(job, in: db)
        return job
    }
}

extension JobRecord {
    // A title is required. Any other blank text is no value. Only a waiting job says what it
    // waits for.
    nonisolated fileprivate mutating func apply(_ fact: JobFact) throws {
        switch fact {
        case .title(let text):
            guard let title = Self.text(text) else {
                throw JobValidationError(message: "Write a title for this job.")
            }
            self.title = title
        case .problem(let text):
            problem = Self.text(text)
        case .waitingFor(let text):
            let value = Self.text(text)
            guard value == nil || stage == .waiting else { throw JobError.notWaiting }
            waitingFor = value
        }
    }

    nonisolated private static func text(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
