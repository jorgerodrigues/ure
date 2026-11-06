import Foundation

// An amount of money in one currency, such as £12.90. The amount is an exact decimal, never a
// floating-point number, and the currency is its ISO code, such as "GBP".
nonisolated struct Money: Equatable, Hashable, Sendable {
    let amount: Decimal
    let currency: String

    init(_ amount: Decimal, _ currency: String) {
        self.amount = amount
        self.currency = currency
    }

    // The amount in the Mac's region format with its currency, such as "€21.40" or "21,40 €".
    func formatted(locale: Locale = .current) -> String {
        amount.formatted(.currency(code: currency).locale(locale))
    }

    // The amount in the region format without its currency, with the currency's decimals, such
    // as "12.90". A field shows it beside the currency's pop-up.
    func number(locale: Locale = .current) -> String {
        let digits = CurrencyRules.fractionDigits(of: currency)
        return amount.formatted(.number.locale(locale).precision(.fractionLength(digits)))
    }
}

// What an amount comes to in the home currency: the amount itself when it is in the home
// currency, or an estimate from a rate you set, marked with ≈.
nonisolated struct HomeAmount: Equatable, Sendable {
    let money: Money
    let isEstimate: Bool

    func formatted(locale: Locale = .current) -> String {
        let text = money.formatted(locale: locale)
        return isEstimate ? "≈ \(text)" : text
    }
}

// The rates you set, each the value of one unit of a currency in your home currency, such as
// £1 = €1.16. The app never fetches them.
nonisolated struct ExchangeRates: Equatable, Sendable {
    var home: String
    var rates: [String: Decimal] = [:]

    // An amount in the home currency. Another currency gives an estimate from its rate, rounded
    // to the home currency's cents, and nil when no rate is set for it.
    func inHome(_ money: Money) -> HomeAmount? {
        if money.currency == home { return HomeAmount(money: money, isEstimate: false) }
        guard let rate = rates[money.currency] else { return nil }
        let value = CurrencyRules.rounded(money.amount * rate, to: home)
        return HomeAmount(money: Money(value, home), isEstimate: true)
    }
}

// What the app knows about currencies, from the system's ISO 4217 list.
nonisolated enum CurrencyRules {
    // The currency of the Mac's region, or the euro when the region has none.
    static func regionCurrency(_ locale: Locale = .current) -> String {
        if let code = locale.currency?.identifier, isKnown(code) { return code }
        return "EUR"
    }

    static func isKnown(_ code: String) -> Bool { known.contains(code) }

    // Every currency the system knows, in order of code.
    static var codes: [String] { known.sorted() }

    // How many decimals the currency has: 2 for the euro, 0 for the yen, 3 for the dinar.
    static func fractionDigits(of code: String) -> Int { fractionDigits[code] ?? 2 }

    // The currency's name in the region's language, such as "British Pound".
    static func name(of code: String, locale: Locale = .current) -> String {
        locale.localizedString(forCurrencyCode: code) ?? code
    }

    // The currency's symbol in the region, such as "£", or its code when it has none.
    static func symbol(of code: String, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = code
        return formatter.currencySymbol ?? code
    }

    // A value rounded to the currency's decimals, halves away from zero.
    static func rounded(_ value: Decimal, to code: String) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, fractionDigits(of: code), .plain)
        return result
    }

    // The currency a typed mark names, such as "£", "GBP" or "kr.". The symbols of the
    // amount's own currency and of the home currency come first, so "kr." is the Danish krone
    // in Denmark and the Swedish krona in Sweden. Nil when the mark names no currency the app
    // knows.
    static func currency(
        forMark mark: String, current: String, home: String, locale: Locale = .current
    ) -> String? {
        let typed = mark.trimmingCharacters(in: .whitespaces)
        if isKnown(typed.uppercased()) { return typed.uppercased() }
        let key = normalized(typed)
        for code in [current, home] where normalized(symbol(of: code, locale: locale)) == key {
            return code
        }
        return commonMarks[key]
    }

    private static let known: Set<String> = Set(
        Locale.Currency.isoCurrencies.map(\.identifier).filter { code in
            code.count == 3 && code.allSatisfy { $0.isASCII && $0.isUppercase }
        })

    private static let fractionDigits: [String: Int] = Dictionary(
        uniqueKeysWithValues: known.map { code in
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.currencyCode = code
            return (code, formatter.maximumFractionDigits)
        })

    // Marks that name one currency wherever you are.
    private static let commonMarks: [String: String] = [
        "€": "EUR", "£": "GBP", "$": "USD", "us$": "USD", "¥": "JPY", "jp¥": "JPY", "₹": "INR",
        "fr": "CHF", "kr": "DKK", "a$": "AUD", "ca$": "CAD", "nz$": "NZD", "hk$": "HKD",
    ]

    private static func normalized(_ mark: String) -> String {
        let lower = mark.trimmingCharacters(in: .whitespaces).lowercased()
        return lower.hasSuffix(".") ? String(lower.dropLast()) : lower
    }
}
