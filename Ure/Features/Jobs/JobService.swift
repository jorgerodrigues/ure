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

    // Opens a job In progress. The watch must not be archived and must have no open job.
    func start(for watchID: UUID, title: String = newTitle) async throws -> JobRecord {
        try await coordinator.mutate { db, _, dependencies in
            guard try WatchQueries.fetch(watchID, in: db) != nil else {
                throw JobError.unavailableWatch
            }
            try RecordAccess.requireWatch(watchID, in: db)
            if let existing = try JobQueries.openJob(for: watchID, in: db) {
                throw JobError.openJobExists(existing)
            }
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            var record = JobRecord(
                id: dependencies.makeID(), watchID: watchID, title: Self.newTitle,
                stage: .inProgress, createdAt: now, updatedAt: now)
            try record.apply(.title(title))
            try JobQueries.insert(record, in: db)
            return record
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
    // Done and when its watch is archived.
    static func requireJob(_ id: UUID, in db: Database) throws -> JobRecord {
        guard let job = try JobQueries.fetch(id, in: db) else { throw JobError.missingRecord }
        guard job.archivedAt == nil else { throw ArchiveError.archived }
        return job
    }

    private static func write(
        _ value: JobStageValue, to existing: JobRecord, at now: Date, in db: Database
    ) throws -> JobRecord {
        guard JobStageValue(job: existing) != value else { return existing }
        if value.stage.isOpen, !existing.stage.isOpen,
            let open = try JobQueries.openJob(for: existing.watchID, in: db)
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
