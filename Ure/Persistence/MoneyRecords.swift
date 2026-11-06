import Foundation
import GRDB

// A rate you set for a currency: what one unit of it is worth in a home currency, such as
// £1 = €1.16. Rates are kept for each home currency, so a home currency you choose again finds
// its rates again.
nonisolated struct CurrencyRateRecord: Codable, Equatable, Sendable, FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "currencyRate"

    let homeCurrency: String
    let currency: String
    var rate: Decimal
    var updatedAt: Date

    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }
    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
}

// The home currency you chose, or nil to use the Mac's region, the rates you set, and the
// currencies the library's prices are in.
nonisolated struct MoneySettings: Equatable, Sendable {
    var homeCurrency: String?
    var rates: [CurrencyRateRecord] = []
    var usedCurrencies: [String] = []

    func home(region: String) -> String { homeCurrency ?? region }

    // The rates set for the home currency.
    func exchangeRates(region: String) -> ExchangeRates {
        let home = home(region: region)
        var found: [String: Decimal] = [:]
        for record in rates where record.homeCurrency == home {
            found[record.currency] = record.rate
        }
        return ExchangeRates(home: home, rates: found)
    }
}

nonisolated enum MoneyQueries {
    static let homeCurrencySetting = "homeCurrency"

    static func homeCurrency(_ db: Database) throws -> String? {
        try String.fetchOne(
            db, sql: "SELECT value FROM librarySetting WHERE name = ?",
            arguments: [homeCurrencySetting])
    }

    // The home currency you chose, or the region's when you chose none.
    static func homeCurrency(_ db: Database, region: String) throws -> String {
        try homeCurrency(db) ?? region
    }

    static func settings(_ db: Database) throws -> MoneySettings {
        MoneySettings(
            homeCurrency: try homeCurrency(db),
            rates: try CurrencyRateRecord.fetchAll(
                db, sql: "SELECT * FROM currencyRate ORDER BY homeCurrency, currency"),
            usedCurrencies: try String.fetchAll(
                db,
                sql: """
                    SELECT currency FROM partOption WHERE currency IS NOT NULL
                    UNION SELECT boughtCurrency FROM part WHERE boughtCurrency IS NOT NULL
                    UNION SELECT paidCurrency FROM part WHERE paidCurrency IS NOT NULL
                    ORDER BY 1
                    """))
    }

    // Sets the home currency, or goes back to the region's with nil.
    static func setHomeCurrency(_ code: String?, in db: Database) throws {
        if let code {
            try db.execute(
                sql: """
                    INSERT INTO librarySetting (name, value) VALUES (?, ?)
                    ON CONFLICT(name) DO UPDATE SET value = excluded.value
                    """, arguments: [homeCurrencySetting, code])
        } else {
            try db.execute(
                sql: "DELETE FROM librarySetting WHERE name = ?", arguments: [homeCurrencySetting])
        }
    }

    // Sets the rate of a currency in the home currency, or takes it away with nil.
    static func setRate(
        _ rate: Decimal?, for currency: String, home: String, at time: Date, in db: Database
    ) throws {
        if let rate {
            try CurrencyRateRecord(
                homeCurrency: home, currency: currency, rate: rate, updatedAt: time
            ).save(db)
        } else {
            try db.execute(
                sql: "DELETE FROM currencyRate WHERE homeCurrency = ? AND currency = ?",
                arguments: [home, currency])
        }
    }
}
