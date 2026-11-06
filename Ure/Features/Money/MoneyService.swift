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

    // Saves the rate of one unit of a currency in a home currency, the current one unless
    // another is given, typed as on paper, such as "1.16". A rate field gives the home currency
    // it was made for, so its Undo never reaches another home currency's rate. A blank rate
    // takes it away, so prices in that currency show no estimate.
    func setRate(_ text: String, for currency: String, home given: String? = nil) async throws {
        guard CurrencyRules.isKnown(currency) else { throw PartError.unknownCurrency }
        try await coordinator.mutate { [region, locale] db, _, dependencies in
            let home = try given ?? MoneyQueries.homeCurrency(db, region: region)
            guard currency != home else { return }
            let rate: Decimal?
            do throws(MoneyEntryProblem) {
                rate =
                    try MoneyEntry.rate.read(text, currency: home, home: home, locale: locale)?
                    .amount
            } catch {
                throw PartValidationError(message: error.message)
            }
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            try MoneyQueries.setRate(rate, for: currency, home: home, at: now, in: db)
        }
    }
}
