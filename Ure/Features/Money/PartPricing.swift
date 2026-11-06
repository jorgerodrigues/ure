import Foundation

// How a part's options compare, and what was paid, in the home currency.
nonisolated enum PartPricing {
    // The option marked Lowest: the lowest price with shipping in the home currency, among at
    // least two options that can be compared there. Of two equal ones, the first wins.
    static func lowest(_ options: [PartOption], rates: ExchangeRates) -> UUID? {
        let compared = options.compactMap { option -> (id: UUID, amount: Decimal)? in
            guard let total = option.total, let home = rates.inHome(total) else { return nil }
            return (option.id, home.money.amount)
        }
        guard compared.count >= 2 else { return nil }
        return compared.min { $0.amount < $1.amount }?.id
    }

    // The lowest price with shipping in the home currency, such as "from €21.40" for a part to
    // buy, or nil when no option has a price that can be shown there.
    static func lowestPrice(_ options: [PartOption], rates: ExchangeRates) -> HomeAmount? {
        options.compactMap { $0.total.flatMap(rates.inHome) }
            .min { $0.money.amount < $1.money.amount }
    }

    // What was paid for the parts, added up per currency, the home currency first. Only the
    // amounts charged to you count, never a shop's prices.
    static func paid(_ parts: [PartRecord], home: String) -> [Money] {
        var totals: [String: Decimal] = [:]
        for part in parts {
            guard let paid = part.purchase?.paid else { continue }
            totals[paid.currency, default: 0] += paid.amount
        }
        return totals.map { Money($0.value, $0.key) }.sorted { lhs, rhs in
            if (lhs.currency == home) != (rhs.currency == home) { return lhs.currency == home }
            return lhs.currency < rhs.currency
        }
    }
}

// How prices and payments read, as on the "3 Parts", "3b Part, after Buy" and "3c Mark as
// bought" artboards.
nonisolated enum PartMoneyWording {
    // What a job's parts cost you, such as "€42.40 paid". Amounts in an earlier home currency
    // follow, such as "€42.40 + 120,00 kr. paid". Nil when nothing was paid.
    static func paid(_ totals: [Money], locale: Locale = .current) -> String? {
        guard !totals.isEmpty else { return nil }
        return totals.map { $0.formatted(locale: locale) }.joined(separator: " + ") + " paid"
    }

    // An option's price with shipping, in the home currency when it can be, such as "≈ €21.40",
    // or in its own currency when no rate is set, such as "$30.45". Nil while it has no price.
    static func headline(of option: PartOption, rates: ExchangeRates, locale: Locale = .current)
        -> String?
    {
        guard let total = option.total else { return nil }
        if let home = rates.inHome(total) { return home.formatted(locale: locale) }
        return total.formatted(locale: locale)
    }

    // The price and the shipping under an option's headline, such as "£12.90 + £5.50 shipping"
    // or "free shipping". A price in the home currency with no shipping given needs no line.
    static func breakdown(
        of option: PartOption, rates: ExchangeRates, saysShipping: Bool = true,
        locale: Locale = .current
    ) -> String? {
        guard let price = option.price, let currency = option.currency else {
            return "No price yet"
        }
        return breakdown(
            price: Money(price, currency), shipping: option.shipping, home: rates.home,
            saysShipping: saysShipping, locale: locale)
    }

    static func breakdown(
        price: Money, shipping: Decimal?, home: String, saysShipping: Bool = true,
        locale: Locale = .current
    ) -> String? {
        let isHome = price.currency == home
        let shown = price.formatted(locale: locale)
        guard let shipping else { return isHome ? nil : shown }
        if shipping == 0 { return isHome ? "free shipping" : "\(shown), free shipping" }
        let added = Money(shipping, price.currency).formatted(locale: locale)
        return "\(shown) + \(added)" + (saysShipping ? " shipping" : "")
    }

    // The options a bought part kept, such as "2 other options kept · eBay €24.00, Esslinger
    // ≈ €26.40".
    static func keptOptions(
        _ options: [PartOption], rates: ExchangeRates, locale: Locale = .current
    ) -> String {
        let count =
            options.count == 1 ? "1 other option kept" : "\(options.count) other options kept"
        let listed = options.map { option in
            [option.supplier, headline(of: option, rates: rates, locale: locale)]
                .compactMap { $0 }.joined(separator: " ")
        }
        return ([count] + [listed.joined(separator: ", ")]).filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
