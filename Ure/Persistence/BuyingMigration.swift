import Foundation
import GRDB

// Before v27, a part kept saved links that held only a URL. Each link is now a buying option
// with the same ID, part, place and times. Its supplier is the link's host without "www.", and
// it has no price yet. A part also keeps what was bought for it, and the library keeps your
// home currency and the exchange rates you set. Money is stored as exact decimal text with an
// ISO currency code, never as a floating-point number. Nothing typed is lost.
nonisolated enum BuyingMigration {
    static func turnLinksIntoOptions(in db: Database) throws {
        try createOptionTable(in: db)
        let links = try Row.fetchAll(
            db,
            sql: "SELECT id, partID, position, url, createdAt, updatedAt FROM partLink ORDER BY id"
        )
        for link in links {
            let url: String = link["url"]
            try db.execute(
                sql: """
                    INSERT INTO partOption (id, partID, position, supplier, url, createdAt,
                        updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    link["id"], link["partID"], link["position"], supplier(for: url), url,
                    link["createdAt"], link["updatedAt"],
                ])
        }
        try db.drop(table: "partLink")
        try addPurchase(in: db)
        try createMoneyTables(in: db)
    }

    // The supplier an option from a saved link starts with: the link's host without "www.", as
    // a link in Material is titled, or the link itself when it has no host.
    static func supplier(for url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = WebLink.url(from: trimmed) else { return trimmed }
        return WebLink.title(for: parsed)
    }

    // An exact decimal kept as text, such as "12.9", or no value.
    static func decimalCheck(_ column: String) -> String {
        """
        \(column) IS NULL OR (
            typeof(\(column)) = 'text' AND \(column) GLOB '[0-9]*' AND
            \(column) NOT GLOB '*[^0-9.]*' AND substr(\(column), -1) GLOB '[0-9]' AND
            length(\(column)) - length(replace(\(column), '.', '')) <= 1
        )
        """
    }

    // An ISO currency code, such as "GBP", or no value.
    static func currencyCheck(_ column: String) -> String {
        "\(column) IS NULL OR (length(\(column)) = 3 AND \(column) NOT GLOB '*[^A-Z]*')"
    }

    private static func createOptionTable(in db: Database) throws {
        try db.create(table: "partOption") { table in
            table.column("id", .text).primaryKey()
            table.column("partID", .text).notNull().references("part", onDelete: .restrict)
            table.column("position", .integer).notNull().check { $0 >= 0 }
            table.column("supplier", .text).notNull().check(sql: "length(trim(supplier)) > 0")
            table.column("url", .text).notNull().check(sql: "length(trim(url)) > 0")
            table.column("price", .text).check(sql: decimalCheck("price"))
            table.column("shipping", .text).check(sql: decimalCheck("shipping"))
            table.column("currency", .text).check(sql: currencyCheck("currency"))
            table.column("note", .text).notNull().defaults(to: "")
            table.column("createdAt", .double).notNull()
            table.column("updatedAt", .double).notNull()
            // A price or shipping is always in a currency.
            table.check(sql: "(price IS NULL AND shipping IS NULL) OR currency IS NOT NULL")
        }
        try db.create(
            index: "partOption_partID_position", on: "partOption", columns: ["partID", "position"])
    }

    // What was bought for a part. A purchase has a price in a currency and what you paid in your
    // home currency, and only a part that is no longer Needed has one.
    private static func addPurchase(in db: Database) throws {
        // Each check names only the columns added before it, so what you paid comes first.
        try db.alter(table: "part") { table in
            table.add(column: "paid", .text)
                .check(sql: decimalCheck("paid"))
                .check(sql: "paid IS NULL OR stage != 'Needed'")
            table.add(column: "paidCurrency", .text)
                .check(sql: currencyCheck("paidCurrency"))
                .check(sql: "(paidCurrency IS NULL) = (paid IS NULL)")
            table.add(column: "boughtPrice", .text)
                .check(sql: decimalCheck("boughtPrice"))
                .check(sql: "(boughtPrice IS NULL) = (paid IS NULL)")
            table.add(column: "boughtShipping", .text)
                .check(sql: decimalCheck("boughtShipping"))
                .check(sql: "boughtShipping IS NULL OR boughtPrice IS NOT NULL")
            table.add(column: "boughtCurrency", .text)
                .check(sql: currencyCheck("boughtCurrency"))
                .check(sql: "(boughtCurrency IS NULL) = (boughtPrice IS NULL)")
            table.add(column: "boughtFrom", .text)
                .check(sql: "boughtFrom IS NULL OR paid IS NOT NULL")
            table.add(column: "boughtURL", .text)
                .check(sql: "boughtURL IS NULL OR paid IS NOT NULL")
            table.add(column: "boughtOptionID", .text)
                .check(sql: "boughtOptionID IS NULL OR paid IS NOT NULL")
        }
    }

    // Your home currency, when you chose one, and the rates you set, each for one home currency.
    private static func createMoneyTables(in db: Database) throws {
        try db.create(table: "librarySetting") { table in
            table.column("name", .text).primaryKey()
                .check(sql: "name IN ('\(MoneyQueries.homeCurrencySetting)')")
            table.column("value", .text).notNull()
                .check(sql: currencyCheck("value"))
        }
        try db.create(table: "currencyRate") { table in
            table.column("homeCurrency", .text).notNull()
                .check(sql: currencyCheck("homeCurrency"))
            table.column("currency", .text).notNull().check(sql: currencyCheck("currency"))
            table.column("rate", .text).notNull()
                .check(sql: decimalCheck("rate"))
                .check(sql: "rate GLOB '*[1-9]*'")
            table.column("updatedAt", .double).notNull()
            table.primaryKey(["homeCurrency", "currency"])
            table.check(sql: "homeCurrency != currency")
        }
    }
}
