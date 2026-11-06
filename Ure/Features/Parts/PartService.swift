import AppKit
import Foundation
import GRDB

nonisolated enum PartError: LocalizedError, Equatable {
    case missingRecord
    case spareTaken
    case invalidQuantity
    case missingOption
    case unknownCurrency
    case invalidPurchase

    var errorDescription: String? {
        switch self {
        case .missingRecord: "This part is no longer available."
        case .spareTaken: "This spare is no longer in the drawer. Type the part to add it."
        case .invalidQuantity: "Enter a whole number above 0."
        case .missingOption: "This option is no longer on the part."
        case .unknownCurrency: "Choose a currency the app knows."
        case .invalidPurchase: "Enter a price above 0 and what you were charged."
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

// One fact of a buying option, written in place on the part's page. The price and the
// shipping are typed as on a receipt, and a currency typed with them sets the option's currency.
nonisolated enum PartOptionFact: Equatable, Sendable {
    case supplier(String)
    case price(String)
    case shipping(String)
    case currency(String)
    case note(String)
}

// A part's state with the dates and the purchase that belong to it. Undo puts back exactly
// these.
nonisolated struct PartStageValue: Equatable, Sendable {
    let stage: PartStage
    var orderedAt: Date? = nil
    var inHandAt: Date? = nil
    var fittedAt: Date? = nil
    var purchase: PartPurchase? = nil

    init(
        stage: PartStage, orderedAt: Date? = nil, inHandAt: Date? = nil, fittedAt: Date? = nil,
        purchase: PartPurchase? = nil
    ) {
        self.stage = stage
        self.orderedAt = orderedAt
        self.inHandAt = inHandAt
        self.fittedAt = fittedAt
        self.purchase = purchase
    }

    init(part: PartRecord) {
        stage = part.stage
        orderedAt = part.orderedAt
        inHandAt = part.inHandAt
        fittedAt = part.fittedAt
        purchase = part.purchase
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

// A part that was removed, with its options, so that Undo can put both back.
nonisolated struct RemovedPart: Equatable, Sendable {
    let part: PartRecord
    let options: [PartOption]
}

nonisolated struct PartService: Sendable {
    static let newName = "New Part"

    let coordinator: LibraryCoordinator
    var openBrowser: @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }
    // The currency of the Mac's region, the home currency until you choose another.
    var region = CurrencyRules.regionCurrency()
    var locale = Locale.current

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
    func update(_ id: UUID, _ fact: PartFact) async throws -> Revision<PartRecord> {
        try await coordinator.mutate { db, _, dependencies in
            var record = try Self.requirePart(id, in: db)
            let saved = record
            try record.apply(fact)
            guard record != saved else { return Revision(before: saved, after: saved) }
            record.updatedAt = Date(
                timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            try PartQueries.update(record, in: db)
            return Revision(before: saved, after: record)
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
    func restoreStage(_ id: UUID, to value: PartStageValue) async throws -> PartStageChange {
        try await coordinator.mutate { db, _, dependencies in
            let existing = try Self.requirePart(id, in: db)
            let part = try Self.write(value, to: existing, at: dependencies.now(), in: db)
            return PartStageChange(prior: PartStageValue(part: existing), part: part)
        }
    }

    // Moves a spare that is in hand from the drawer to the end of a job's parts.
    func useSpare(_ id: UUID, on jobID: UUID) async throws -> Revision<PartRecord> {
        try await coordinator.mutate { db, _, dependencies in
            let spare = try Self.requirePart(id, in: db)
            guard spare.isSpare, spare.stage == .inHand else { throw PartError.spareTaken }
            _ = try JobService.requireJob(jobID, in: db)
            let placement = PartPlacement(
                jobID: jobID, position: try PartQueries.nextPosition(on: jobID, in: db))
            let used = try Self.place(spare, at: placement, time: dependencies.now(), in: db)
            return Revision(before: spare, after: used)
        }
    }

    // Puts a part back where it was, on a job or in the drawer. Undo and Redo of a spare's use
    // call it.
    func place(_ id: UUID, at placement: PartPlacement) async throws -> Revision<PartRecord> {
        try await coordinator.mutate { db, _, dependencies in
            let part = try Self.requirePart(id, in: db)
            if let jobID = placement.jobID { _ = try JobService.requireJob(jobID, in: db) }
            let placed = try Self.place(part, at: placement, time: dependencies.now(), in: db)
            return Revision(before: part, after: placed)
        }
    }

    // Removes a part with its options. The result lets Undo put both back.
    func remove(_ id: UUID) async throws -> RemovedPart {
        try await coordinator.mutate { db, _, _ in
            let part = try Self.requirePart(id, in: db)
            let options = try PartQueries.options(of: id, in: db)
            try db.execute(
                sql: "DELETE FROM partOption WHERE partID = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM part WHERE id = ?", arguments: [id.uuidString])
            return RemovedPart(part: part, options: options)
        }
    }

    // Puts back a removed part with its options, as they were.
    func restore(_ removed: RemovedPart) async throws -> PartRecord {
        try await coordinator.mutate { db, _, _ in
            if let jobID = removed.part.jobID { _ = try JobService.requireJob(jobID, in: db) }
            try PartQueries.insert(removed.part, in: db)
            for option in removed.options { try option.insert(db) }
            return removed.part
        }
    }

    // Adds a buying option for a pasted link, after the part's other options. Its supplier is
    // the link's host without "www.", and it has no price until you type one.
    func addOption(_ url: URL, to partID: UUID) async throws -> PartOption {
        try await coordinator.mutate { db, _, dependencies in
            _ = try Self.requirePart(partID, in: db)
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            let option = PartOption(
                id: dependencies.makeID(), partID: partID,
                position: try PartQueries.nextOptionPosition(on: partID, in: db),
                supplier: WebLink.title(for: url), url: url.absoluteString, createdAt: now,
                updatedAt: now)
            try option.insert(db)
            return option
        }
    }

    // Saves one fact of an option. A value that is already saved changes nothing, not even the
    // edit time.
    func updateOption(_ id: UUID, _ fact: PartOptionFact) async throws -> PartOption {
        try await coordinator.mutate { [region, locale] db, _, dependencies in
            var option = try Self.requireOption(id, in: db)
            let saved = option
            let home = try MoneyQueries.homeCurrency(db, region: region)
            try option.apply(fact, home: home, locale: locale)
            guard option != saved else { return saved }
            option.updatedAt = Date(
                timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            try option.update(db)
            return option
        }
    }

    // Removes an option. Undo puts it back with restoreOption.
    func removeOption(_ id: UUID) async throws -> PartOption {
        try await coordinator.mutate { db, _, _ in
            let option = try Self.requireOption(id, in: db)
            try db.execute(sql: "DELETE FROM partOption WHERE id = ?", arguments: [id.uuidString])
            return option
        }
    }

    // Puts back a removed option as it was.
    func restoreOption(_ option: PartOption) async throws -> PartOption {
        try await coordinator.mutate { db, _, _ in
            _ = try Self.requirePart(option.partID, in: db)
            try option.insert(db)
            return option
        }
    }

    // Records what was bought. A part to buy becomes Ordered from today, and a part further
    // along keeps its state and days. The result has the state before, so Undo puts it back
    // with the purchase it had.
    func markBought(_ id: UUID, _ purchase: PartPurchase) async throws -> PartStageChange {
        try await coordinator.mutate { db, _, dependencies in
            let existing = try Self.requirePart(id, in: db)
            try Self.validate(purchase)
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            var next = PartStageValue(part: existing)
            if existing.stage == .needed {
                next = PartStageValue(stage: .ordered, orderedAt: now)
            }
            next.purchase = purchase
            let part = try Self.write(next, to: existing, at: now, in: db)
            return PartStageChange(prior: PartStageValue(part: existing), part: part)
        }
    }

    @MainActor
    func open(_ link: String) throws {
        guard let url = WebLink.url(from: link) else { throw LinkError.invalidURL }
        guard openBrowser(url) else { throw LinkError.browserUnavailable }
    }

    // A part's options as they are saved.
    func options(of partID: UUID) async throws -> [PartOption] {
        try await coordinator.read { try PartQueries.options(of: partID, in: $0) }
    }

    static func requireOption(_ id: UUID, in db: Database) throws -> PartOption {
        guard let option = try PartQueries.option(id, in: db) else {
            throw PartError.missingOption
        }
        _ = try requirePart(option.partID, in: db)
        return option
    }

    // A purchase has a price above 0, shipping of 0 or more, and an amount charged above 0, in
    // currencies the app knows.
    private static func validate(_ purchase: PartPurchase) throws {
        guard CurrencyRules.isKnown(purchase.price.currency),
            CurrencyRules.isKnown(purchase.paid.currency)
        else { throw PartError.unknownCurrency }
        guard purchase.price.amount > 0, purchase.paid.amount > 0,
            (purchase.shipping ?? 0) >= 0
        else { throw PartError.invalidPurchase }
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
        // A part that goes back to Needed is to buy again, so what was bought goes with its
        // order day. Undo puts both back.
        if stage != .needed { next.purchase = existing.purchase }
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
        part.purchase = value.stage == .needed ? nil : value.purchase
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

extension PartOption {
    // A supplier is required. A blank price or shipping is none. Only the currency's pop-up
    // changes the option's currency, with its own Undo step, so a currency typed with the price
    // or the shipping must be the option's. An option with no amount left in the home currency
    // has no currency of its own again, as it had before its first amount.
    nonisolated fileprivate mutating func apply(
        _ fact: PartOptionFact, home: String, locale: Locale
    ) throws {
        switch fact {
        case .supplier(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw PartValidationError(message: "Enter a supplier.")
            }
            supplier = trimmed
        case .price(let text):
            price = try amount(text, as: .price, home: home, locale: locale)
        case .shipping(let text):
            shipping = try amount(text, as: .shipping, home: home, locale: locale)
        case .currency(let code):
            // An empty code is no currency chosen, which is the home currency once there is an
            // amount. Undo of a first choice puts it back.
            let chosen = code.isEmpty ? nil : code
            if let chosen, !CurrencyRules.isKnown(chosen) { throw PartError.unknownCurrency }
            guard PartOptionRules.fits([price, shipping], in: chosen ?? home) else {
                throw PartValidationError(
                    message: PartOptionRules.tooPrecise(for: chosen ?? home))
            }
            currency = chosen
        case .note(let text):
            note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // An amount is always in a currency, the home currency until you choose another.
        if price != nil || shipping != nil, currency == nil { currency = home }
        if price == nil, shipping == nil, currency == home { currency = nil }
    }

    nonisolated private func amount(
        _ text: String, as entry: MoneyEntry, home: String, locale: Locale
    ) throws -> Decimal? {
        let reading = try read(text, as: entry, home: home, locale: locale)
        if let message = PartOptionRules.conflict(
            typed: reading?.currency, current: currency ?? home)
        {
            throw PartValidationError(message: message)
        }
        return reading?.amount
    }

    nonisolated private func read(
        _ text: String, as entry: MoneyEntry, home: String, locale: Locale
    ) throws -> MoneyEntry.Reading? {
        do throws(MoneyEntryProblem) {
            return try entry.read(text, currency: currency ?? home, home: home, locale: locale)
        } catch {
            throw PartValidationError(message: error.message)
        }
    }
}

// The rules an option's price and shipping follow, which its fields and the service both
// check. They share one currency, which only the currency's pop-up changes.
nonisolated enum PartOptionRules {
    // A currency typed with an amount must be the option's, so typing never relabels an
    // amount or changes the currency outside its own Undo step.
    static func conflict(typed: String?, current: String) -> String? {
        guard let typed, typed != current else { return nil }
        return "Choose \(typed) in the currency menu first. This option is in \(current)."
    }

    // Whether no amount has more decimals than the currency takes, so 12.90 does not fit the
    // yen.
    static func fits(_ amounts: [Decimal?], in code: String) -> Bool {
        let digits = CurrencyRules.fractionDigits(of: code)
        return amounts.compactMap { $0 }.allSatisfy { decimals(of: $0) <= digits }
    }

    static func tooPrecise(for code: String) -> String {
        "The price or the shipping has more decimals than \(code) takes. Change it first."
    }

    private static func decimals(of amount: Decimal) -> Int {
        let text = NSDecimalNumber(decimal: amount).description(
            withLocale: Locale(identifier: "en_US_POSIX"))
        guard let dot = text.firstIndex(of: ".") else { return 0 }
        return text[text.index(after: dot)...].count
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
