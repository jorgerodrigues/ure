import Foundation

// One fact on a caliber page. Each saves on its own, so two fields never overwrite each other.
nonisolated enum CaliberFact: Equatable, Sendable {
    case name(String)
    case maker(String)
    case winding(Winding?)
    case beatRate(Double?)
    case jewels(Double?)
    case powerReserve(Double?)
    case liftAngle(Double?)
}

nonisolated struct CaliberValidationError: LocalizedError, Equatable {
    let message: String

    var errorDescription: String? { message }
}

nonisolated struct CaliberService: Sendable {
    static let newName = "New Caliber"

    let coordinator: LibraryCoordinator

    func create(named name: String = newName) async throws -> CaliberRecord {
        try await coordinator.mutate { db, _, dependencies in
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            var record = CaliberRecord(
                id: dependencies.makeID(), designation: "", createdAt: now, updatedAt: now)
            try record.apply(.name(name))
            try CaliberQueries.insert(record, in: db)
            return record
        }
    }

    // Saves one fact. A value that is already saved changes nothing, not even the edit time.
    func update(_ id: UUID, _ fact: CaliberFact) async throws -> Revision<CaliberRecord> {
        try await coordinator.mutate { db, _, dependencies in
            guard var record = try CaliberQueries.fetch(id, in: db) else {
                throw ArchiveError.missingRecord
            }
            try RecordAccess.requireCaliber(id, in: db)
            let saved = record
            try record.apply(fact)
            guard record != saved else { return Revision(before: saved, after: saved) }
            record.updatedAt = Date(
                timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            try CaliberQueries.update(record, in: db)
            return Revision(before: saved, after: record)
        }
    }
}

extension CaliberRecord {
    nonisolated fileprivate init(
        id: UUID, designation: String, createdAt: Date, updatedAt: Date
    ) {
        self.init(
            id: id, designation: designation, manufacturer: nil, winding: nil, beatRate: nil,
            jewelCount: nil, powerReserve: nil, liftAngle: nil, createdAt: createdAt,
            updatedAt: updatedAt)
    }

    // Names are required. Numbers are finite and zero or more, and a beat rate or lift angle
    // is above zero. A blank maker is no maker.
    nonisolated fileprivate mutating func apply(_ fact: CaliberFact) throws {
        switch fact {
        case .name(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw CaliberValidationError(message: "Write a name for this caliber.")
            }
            designation = trimmed
        case .maker(let maker):
            let trimmed = maker.trimmingCharacters(in: .whitespacesAndNewlines)
            manufacturer = trimmed.isEmpty ? nil : trimmed
        case .winding(let value):
            winding = value
        case .beatRate(let value):
            beatRate = try Self.checked(value, aboveZero: true)
        case .jewels(let value):
            jewelCount = try Self.checked(value, aboveZero: false)
        case .powerReserve(let value):
            powerReserve = try Self.checked(value, aboveZero: false)
        case .liftAngle(let value):
            liftAngle = try Self.checked(value, aboveZero: true)
        }
    }

    nonisolated private static func checked(_ value: Double?, aboveZero: Bool) throws -> Double? {
        guard let value else { return nil }
        guard value.isFinite, value >= 0, !aboveZero || value > 0 else {
            throw CaliberValidationError(message: "This number is out of range.")
        }
        return value
    }
}
