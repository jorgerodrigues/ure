import Foundation
import GRDB

// Where a part is on its way to the watch. A click on a part's state moves it on: Needed,
// Ordered, In hand, then Fitted, the last. Each state after Needed records the day it came.
nonisolated enum PartStage: String, Codable, CaseIterable, Identifiable, Sendable {
    case needed = "Needed"
    case ordered = "Ordered"
    case inHand = "In hand"
    case fitted = "Fitted"

    var id: Self { self }

    // The state a click moves the part to, or nil once it is fitted.
    var next: PartStage? {
        switch self {
        case .needed: .ordered
        case .ordered: .inHand
        case .inHand: .fitted
        case .fitted: nil
        }
    }

    // Whether the part has come this far, such as an In hand part that was ordered.
    func hasReached(_ milestone: PartStage) -> Bool {
        let order = Self.allCases
        return (order.firstIndex(of: self) ?? 0) >= (order.firstIndex(of: milestone) ?? 0)
    }
}

// A part is a record of its own. It belongs to a job, or it is a spare in the drawer when it has
// no job. Each part has a name, a free-text description, a quantity, a state with the dates it
// was ordered, came in hand and was fitted, and notes.
nonisolated struct PartRecord: Codable, Equatable, Identifiable, Sendable, FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "part"

    let id: UUID
    // The job the part is for, or nil for a spare.
    var jobID: UUID?
    // The part's place among its job's parts.
    var position: Int
    var name: String
    var description: String? = nil
    var quantity: Int = 1
    var stage: PartStage = .needed
    var orderedAt: Date? = nil
    var inHandAt: Date? = nil
    var fittedAt: Date? = nil
    var notes = ""
    // What was bought, once Mark as Bought records it. The price and shipping are in the shop's
    // currency, and what you paid is in your home currency.
    var boughtFrom: String? = nil
    var boughtURL: String? = nil
    var boughtOptionID: UUID? = nil
    var boughtPrice: Decimal? = nil
    var boughtShipping: Decimal? = nil
    var boughtCurrency: String? = nil
    var paid: Decimal? = nil
    var paidCurrency: String? = nil
    let createdAt: Date
    var updatedAt: Date

    var isSpare: Bool { jobID == nil }

    // What was bought, or nil while nothing is.
    var purchase: PartPurchase? {
        get {
            guard let paid, let paidCurrency, let boughtPrice, let boughtCurrency else {
                return nil
            }
            return PartPurchase(
                supplier: boughtFrom, url: boughtURL, optionID: boughtOptionID,
                price: Money(boughtPrice, boughtCurrency), shipping: boughtShipping,
                paid: Money(paid, paidCurrency))
        }
        set {
            boughtFrom = newValue?.supplier
            boughtURL = newValue?.url
            boughtOptionID = newValue?.optionID
            boughtPrice = newValue?.price.amount
            boughtShipping = newValue?.shipping
            boughtCurrency = newValue?.price.currency
            paid = newValue?.paid.amount
            paidCurrency = newValue?.paid.currency
        }
    }

    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }
    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
}

// What was bought for a part: from which supplier and listing, the price and the shipping in
// the shop's currency, and the amount charged to you in your home currency.
nonisolated struct PartPurchase: Equatable, Sendable {
    var supplier: String?
    var url: String?
    // The option it was bought from, so the part's page lists the other options it kept.
    var optionID: UUID?
    var price: Money
    // The shipping in the price's currency, or nil when there was none to pay or it is not known.
    var shipping: Decimal?
    var paid: Money

    // The price with the shipping, in the shop's currency.
    var total: Money { Money(price.amount + (shipping ?? 0), price.currency) }
}

// One place a part can be bought: a supplier and its listing, with a price, shipping, the
// currency they are in and a note. A part keeps every option it has, also once it is bought.
nonisolated struct PartOption: Codable, Equatable, Identifiable, Sendable, FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "partOption"

    let id: UUID
    let partID: UUID
    var position: Int
    var supplier: String
    var url: String
    var price: Decimal? = nil
    // Nil when the shipping is not known yet, and 0 when it is free.
    var shipping: Decimal? = nil
    var currency: String? = nil
    var note = ""
    let createdAt: Date
    var updatedAt: Date

    // The price with its shipping, or nil while it has no price.
    var total: Money? {
        guard let price, let currency else { return nil }
        return Money(price + (shipping ?? 0), currency)
    }

    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }
    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
}

// Every part and every buying option, as the parts state observes them.
nonisolated struct PartLibrary: Equatable, Sendable {
    var parts: [PartRecord] = []
    var options: [UUID: [PartOption]] = [:]
}

nonisolated enum PartQueries {
    static func fetchAll(_ db: Database) throws -> [PartRecord] {
        try PartRecord.fetchAll(db, sql: "SELECT * FROM part ORDER BY position, createdAt, id")
    }

    static func library(_ db: Database) throws -> PartLibrary {
        let options = try PartOption.fetchAll(
            db, sql: "SELECT * FROM partOption ORDER BY position, createdAt, id")
        return PartLibrary(
            parts: try fetchAll(db), options: Dictionary(grouping: options, by: \.partID))
    }

    static func fetch(_ id: UUID, in db: Database) throws -> PartRecord? {
        try PartRecord.fetchOne(
            db, sql: "SELECT * FROM part WHERE id = ?", arguments: [id.uuidString])
    }

    static func options(of id: UUID, in db: Database) throws -> [PartOption] {
        try PartOption.fetchAll(
            db, sql: "SELECT * FROM partOption WHERE partID = ? ORDER BY position, createdAt, id",
            arguments: [id.uuidString])
    }

    static func option(_ id: UUID, in db: Database) throws -> PartOption? {
        try PartOption.fetchOne(
            db, sql: "SELECT * FROM partOption WHERE id = ?", arguments: [id.uuidString])
    }

    // The place after the part's last option.
    static func nextOptionPosition(on partID: UUID, in db: Database) throws -> Int {
        try Int.fetchOne(
            db, sql: "SELECT coalesce(max(position) + 1, 0) FROM partOption WHERE partID = ?",
            arguments: [partID.uuidString]) ?? 0
    }

    // The place after the job's last part.
    static func nextPosition(on jobID: UUID, in db: Database) throws -> Int {
        try Int.fetchOne(
            db, sql: "SELECT coalesce(max(position) + 1, 0) FROM part WHERE jobID = ?",
            arguments: [jobID.uuidString]) ?? 0
    }

    static func insert(_ record: PartRecord, in db: Database) throws {
        try record.insert(db)
        try SearchKey.refresh(record.id, table: .part, in: db)
    }

    static func update(_ record: PartRecord, in db: Database) throws {
        try record.update(db)
        try SearchKey.refresh(record.id, table: .part, in: db)
    }
}
