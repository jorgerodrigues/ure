import Foundation

nonisolated enum WatchError: LocalizedError {
    case unavailableCaliber

    var errorDescription: String? {
        switch self {
        case .unavailableCaliber:
            "This caliber is no longer available. Choose another caliber or clear the link."
        }
    }
}

// One fact on a watch page. Each saves on its own, so two fields never overwrite each other.
nonisolated enum WatchFact: Equatable, Sendable {
    case name(String)
    case brand(String)
    case model(String)
    case reference(String)
    case serial(String)
    case year(String)
    case caliber(UUID?)
    case caseMaterial(String)
    case diameter(Double?)
    case lugWidth(Double?)
    case owner(String)
    case contact(String)
}

nonisolated struct WatchValidationError: LocalizedError, Equatable {
    let message: String

    var errorDescription: String? { message }
}

nonisolated struct WatchService: Sendable {
    static let newName = "New Watch"

    let coordinator: LibraryCoordinator

    func create(named name: String = newName) async throws -> WatchRecord {
        try await coordinator.mutate { db, _, dependencies in
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            var record = WatchRecord(id: dependencies.makeID(), createdAt: now, updatedAt: now)
            try record.apply(.name(name))
            try WatchQueries.insert(record, in: db)
            return record
        }
    }

    // Saves one fact. A value that is already saved changes nothing, not even the edit time.
    func update(_ id: UUID, _ fact: WatchFact) async throws -> WatchRecord {
        try await coordinator.mutate { db, _, dependencies in
            guard var record = try WatchQueries.fetch(id, in: db) else {
                throw ArchiveError.missingRecord
            }
            try RecordAccess.requireWatch(id, in: db)
            let saved = record
            try record.apply(fact)
            guard record != saved else { return saved }
            if let caliberID = record.caliberID, caliberID != saved.caliberID {
                guard let caliber = try CaliberQueries.fetch(caliberID, in: db) else {
                    throw WatchError.unavailableCaliber
                }
                // An archived caliber stays linked to its watches but takes no new ones.
                guard caliber.archivedAt == nil else { throw ArchiveError.archived }
            }
            record.updatedAt = Date(
                timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            try WatchQueries.update(record, in: db)
            return record
        }
    }
}

extension WatchRecord {
    nonisolated fileprivate init(id: UUID, createdAt: Date, updatedAt: Date) {
        self.init(
            id: id, name: "", brand: nil, model: nil, caseReference: nil, serial: nil,
            approximateYear: nil, caliberID: nil, caseMaterial: nil, caseDiameter: nil,
            lugWidth: nil, createdAt: createdAt, updatedAt: updatedAt)
    }

    // A name is required. A blank text is no value, and dimensions are finite and above zero.
    nonisolated fileprivate mutating func apply(_ fact: WatchFact) throws {
        switch fact {
        case .name(let text):
            guard let name = Self.text(text) else {
                throw WatchValidationError(message: "Write a name for this watch.")
            }
            self.name = name
        case .brand(let text): brand = Self.text(text)
        case .model(let text): model = Self.text(text)
        case .reference(let text): caseReference = Self.text(text)
        case .serial(let text): serial = Self.text(text)
        case .year(let text): approximateYear = Self.text(text)
        case .caliber(let id): caliberID = id
        case .caseMaterial(let text): caseMaterial = Self.text(text)
        case .diameter(let value): caseDiameter = try Self.dimension(value)
        case .lugWidth(let value): lugWidth = try Self.dimension(value)
        case .owner(let text): owner = Self.text(text)
        case .contact(let text): contact = Self.text(text)
        }
    }

    nonisolated private static func text(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func dimension(_ value: Double?) throws -> Double? {
        guard let value else { return nil }
        guard value.isFinite, value > 0 else {
            throw WatchValidationError(message: "This number is out of range.")
        }
        return value
    }
}
