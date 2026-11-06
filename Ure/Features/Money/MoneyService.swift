import Foundation
import GRDB

// Saves your home currency and the exchange rates you set in Settings. Every rate is typed by
// you, once per currency, and the app never fetches one.
nonisolated struct MoneyService: Sendable {
    let coordinator: LibraryCoordinator
    // The currency of the Mac's region, the home currency until you choose another.
    var region = CurrencyRules.regionCurrency()
    var locale = Locale.current

    // Chooses the home currency, or goes back to the region's with nil.
    func setHomeCurrency(_ code: String?) async throws {
        if let code, !CurrencyRules.isKnown(code) { throw PartError.unknownCurrency }
        try await coordinator.mutate { db, _, _ in
            try MoneyQueries.setHomeCurrency(code, in: db)
        }
    }

    // Saves the rate of one unit of a currency in a home currency, read from what you typed.
    // A rate field gives the home currency it was made for, so its Undo never reaches another
    // home currency's rate. Nil takes the rate away, so prices in that currency show no
    // estimate. The result has the rate before, for Undo.
    func setRate(_ rate: Decimal?, for currency: String, home: String) async throws
        -> Revision<Decimal?>
    {
        guard CurrencyRules.isKnown(currency), CurrencyRules.isKnown(home) else {
            throw PartError.unknownCurrency
        }
        if let rate, rate <= 0 { throw PartValidationError(message: "Enter a rate above 0.") }
        return try await coordinator.mutate { db, _, dependencies in
            let before = try MoneyQueries.rate(of: currency, home: home, in: db)
            guard currency != home, before != rate else {
                return Revision(before: before, after: before)
            }
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            try MoneyQueries.setRate(rate, for: currency, home: home, at: now, in: db)
            return Revision(before: before, after: rate)
        }
    }
}
