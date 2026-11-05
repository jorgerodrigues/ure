import AppKit
import Foundation
import GRDB

nonisolated enum PartError: LocalizedError, Equatable {
    case missingRecord
    case spareTaken
    case invalidQuantity

    var errorDescription: String? {
        switch self {
        case .missingRecord: "This part is no longer available."
        case .spareTaken: "This spare is no longer in the drawer. Type the part to add it."
        case .invalidQuantity: "Enter a whole number above 0."
        }
    }
}

// One fact on a part's page or line. Each saves on its own, so two fields never overwrite each
// other.
nonisolated enum PartFact: Equatable, Sendable {
    case name(String)
    case description(String)
    case quantity(String)
    case notes(String)
}

// A part's state with the dates that belong to it. Undo puts back exactly these.
nonisolated struct PartStageValue: Equatable, Sendable {
    let stage: PartStage
    var orderedAt: Date? = nil
    var inHandAt: Date? = nil
    var fittedAt: Date? = nil

    init(stage: PartStage, orderedAt: Date? = nil, inHandAt: Date? = nil, fittedAt: Date? = nil) {
        self.stage = stage
        self.orderedAt = orderedAt
        self.inHandAt = inHandAt
        self.fittedAt = fittedAt
    }

    init(part: PartRecord) {
        stage = part.stage
        orderedAt = part.orderedAt
        inHandAt = part.inHandAt
        fittedAt = part.fittedAt
    }
}

// A state change: the part as it was saved, and the state it had before.
nonisolated struct PartStageChange: Equatable, Sendable {
    let prior: PartStageValue
    let part: PartRecord
}

// Where a part sits: on a job at a place among its parts, or in the drawer as a spare.
nonisolated struct PartPlacement: Equatable, Sendable {
    let jobID: UUID?
    let position: Int

    init(jobID: UUID?, position: Int) {
        self.jobID = jobID
        self.position = position
    }

    init(part: PartRecord) {
        jobID = part.jobID
        position = part.position
    }
}

// A part that was removed, with its links, so that Undo can put both back.
nonisolated struct RemovedPart: Equatable, Sendable {
    let part: PartRecord
    let links: [PartLink]
}

nonisolated struct PartService: Sendable {
    static let newName = "New Part"

    let coordinator: LibraryCoordinator
    var openBrowser: @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }

    // Adds a part to the end of a job's parts, Needed, or makes a spare in the drawer, In hand
    // from today. A blank name is the name a new part starts with, and a blank description is
    // none.
    func add(named name: String, description: String = "", to jobID: UUID?) async throws
        -> PartRecord
    {
        try await coordinator.mutate { db, _, dependencies in
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            var position = 0
            if let jobID {
                _ = try JobService.requireJob(jobID, in: db)
                position = try PartQueries.nextPosition(on: jobID, in: db)
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            var record = PartRecord(
                id: dependencies.makeID(), jobID: jobID, position: position,
                name: trimmed.isEmpty ? Self.newName : trimmed, createdAt: now, updatedAt: now)
            let written = description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !written.isEmpty { record.description = written }
            if jobID == nil {
                record.stage = .inHand
                record.inHandAt = now
            }
            try PartQueries.insert(record, in: db)
            return record
        }
    }

    // Saves one fact. A value that is already saved changes nothing, not even the edit time.
    func update(_ id: UUID, _ fact: PartFact) async throws -> PartRecord {
        try await coordinator.mutate { db, _, dependencies in
            var record = try Self.requirePart(id, in: db)
            let saved = record
            try record.apply(fact)
            guard record != saved else { return saved }
            record.updatedAt = Date(
                timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            try PartQueries.update(record, in: db)
            return record
        }
    }

    // Moves a part on to the next state, such as Needed to Ordered, and records the day. A
    // fitted part stays fitted.
    func advance(_ id: UUID) async throws -> PartStageChange {
        try await coordinator.mutate { db, _, dependencies in
            let existing = try Self.requirePart(id, in: db)
            guard let next = existing.stage.next else {
                return PartStageChange(prior: PartStageValue(part: existing), part: existing)
            }
            return try Self.setStage(existing, to: next, at: dependencies.now(), in: db)
        }
    }

    // Moves a part to any state. The state it reaches records the day unless it already has
    // one, and the states after it lose their dates.
    func setStage(_ id: UUID, to stage: PartStage) async throws -> PartStageChange {
        try await coordinator.mutate { db, _, dependencies in
            try Self.setStage(
                try Self.requirePart(id, in: db), to: stage, at: dependencies.now(), in: db)
        }
    }

    // Puts back a state as it was, with its dates. Undo and Redo use it.
    func restoreStage(_ id: UUID, to value: PartStageValue) async throws -> PartRecord {
        try await coordinator.mutate { db, _, dependencies in
            let existing = try Self.requirePart(id, in: db)
            return try Self.write(value, to: existing, at: dependencies.now(), in: db)
        }
    }

    // Moves a spare that is in hand from the drawer to the end of a job's parts.
    func useSpare(_ id: UUID, on jobID: UUID) async throws -> PartRecord {
        try await coordinator.mutate { db, _, dependencies in
            let spare = try Self.requirePart(id, in: db)
            guard spare.isSpare, spare.stage == .inHand else { throw PartError.spareTaken }
            _ = try JobService.requireJob(jobID, in: db)
            let placement = PartPlacement(
                jobID: jobID, position: try PartQueries.nextPosition(on: jobID, in: db))
            return try Self.place(spare, at: placement, time: dependencies.now(), in: db)
        }
    }

    // Puts a part back where it was, on a job or in the drawer. Undo and Redo of a spare's use
    // call it.
    func place(_ id: UUID, at placement: PartPlacement) async throws -> PartRecord {
        try await coordinator.mutate { db, _, dependencies in
            let part = try Self.requirePart(id, in: db)
            if let jobID = placement.jobID { _ = try JobService.requireJob(jobID, in: db) }
            return try Self.place(part, at: placement, time: dependencies.now(), in: db)
        }
    }

    // Removes a part with its links. The result lets Undo put both back.
    func remove(_ id: UUID) async throws -> RemovedPart {
        try await coordinator.mutate { db, _, _ in
            let part = try Self.requirePart(id, in: db)
            let links = try PartQueries.links(of: id, in: db)
            try db.execute(sql: "DELETE FROM partLink WHERE partID = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM part WHERE id = ?", arguments: [id.uuidString])
            return RemovedPart(part: part, links: links)
        }
    }

    // Puts back a removed part with its links, as they were.
    func restore(_ removed: RemovedPart) async throws -> PartRecord {
        try await coordinator.mutate { db, _, _ in
            if let jobID = removed.part.jobID { _ = try JobService.requireJob(jobID, in: db) }
            try PartQueries.insert(removed.part, in: db)
            for link in removed.links { try link.insert(db) }
            return removed.part
        }
    }

    @MainActor
    func open(_ link: PartLink) throws {
        guard let url = WebLink.url(from: link.url) else { throw LinkError.invalidURL }
        guard openBrowser(url) else { throw LinkError.browserUnavailable }
    }

    // A part can change while it is in the library. A part on a job also needs the job to be
    // in the library and not archived. A spare has no job, so it can always change.
    static func requirePart(_ id: UUID, in db: Database) throws -> PartRecord {
        guard let part = try PartQueries.fetch(id, in: db) else { throw PartError.missingRecord }
        if let jobID = part.jobID { _ = try JobService.requireJob(jobID, in: db) }
        return part
    }

    private static func setStage(
        _ existing: PartRecord, to stage: PartStage, at time: Date, in db: Database
    ) throws -> PartStageChange {
        let now = Date(timeIntervalSince1970: time.timeIntervalSince1970)
        let prior = PartStageValue(part: existing)
        guard existing.stage != stage else { return PartStageChange(prior: prior, part: existing) }
        var next = PartStageValue(stage: stage)
        if stage.hasReached(.ordered) { next.orderedAt = existing.orderedAt }
        if stage.hasReached(.inHand) { next.inHandAt = existing.inHandAt }
        switch stage {
        case .needed: break
        case .ordered: next.orderedAt = next.orderedAt ?? now
        case .inHand: next.inHandAt = next.inHandAt ?? now
        case .fitted: next.fittedAt = now
        }
        let part = try write(next, to: existing, at: now, in: db)
        return PartStageChange(prior: prior, part: part)
    }

    private static func write(
        _ value: PartStageValue, to existing: PartRecord, at time: Date, in db: Database
    ) throws -> PartRecord {
        guard PartStageValue(part: existing) != value else { return existing }
        var part = existing
        part.stage = value.stage
        part.orderedAt = value.stage.hasReached(.ordered) ? value.orderedAt : nil
        part.inHandAt = value.stage.hasReached(.inHand) ? value.inHandAt : nil
        part.fittedAt = value.stage.hasReached(.fitted) ? value.fittedAt : nil
        part.updatedAt = Date(timeIntervalSince1970: time.timeIntervalSince1970)
        try PartQueries.update(part, in: db)
        return part
    }

    private static func place(
        _ existing: PartRecord, at placement: PartPlacement, time: Date, in db: Database
    ) throws -> PartRecord {
        guard PartPlacement(part: existing) != placement else { return existing }
        var part = existing
        part.jobID = placement.jobID
        part.position = placement.position
        part.updatedAt = Date(timeIntervalSince1970: time.timeIntervalSince1970)
        try PartQueries.update(part, in: db)
        return part
    }
}

extension PartRecord {
    // A name is required, and so is a whole quantity above 0. A blank description is no
    // description. Notes keep every character typed.
    nonisolated fileprivate mutating func apply(_ fact: PartFact) throws {
        switch fact {
        case .name(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw PartValidationError(message: "Enter a name.") }
            name = trimmed
        case .description(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            description = trimmed.isEmpty ? nil : trimmed
        case .quantity(let text):
            guard let value = PartQuantity.value(of: text) else {
                throw PartError.invalidQuantity
            }
            quantity = value
        case .notes(let text):
            notes = text
        }
    }
}

nonisolated struct PartValidationError: LocalizedError, Equatable {
    let message: String

    var errorDescription: String? { message }
}

// How a quantity is typed: a whole number above 0, such as "2". The digits can be in the
// region's own script.
nonisolated enum PartQuantity {
    static func value(of text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else { return nil }
        var digits = ""
        for character in trimmed {
            guard let value = character.wholeNumberValue else { return nil }
            digits.append(String(value))
        }
        guard let value = Int(digits), value > 0 else { return nil }
        return value
    }
}
