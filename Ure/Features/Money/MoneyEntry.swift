import Foundation

// An amount typed the way you would write it on a receipt, such as "12.90", "£12.90", "12,90 €"
// or "GBP 12.90". The region's decimal mark separates the fraction. The other of "." and ","
// does too when only one or two digits follow it, as in a price copied from a shop abroad.
// Otherwise it groups the digits, as a number does on a caliber page. A currency mark before
// or after the number names its currency. An amount has at most as many decimals as its
// currency, so a price in euros stops at cents.
nonisolated struct MoneyEntry: Sendable {
    enum Minimum: Sendable {
        case zero
        case aboveZero
    }

    // What the amount is, in a sentence, such as "price" or "shipping".
    let name: String
    let minimum: Minimum
    // Whether a currency mark may be typed with the amount. A rate is a plain number.
    var takesCurrency = true
    // The most decimals the amount takes, or nil for the currency's own number of decimals.
    var maximumFractionDigits: Int? = nil

    static let price = MoneyEntry(name: "price", minimum: .aboveZero)
    static let shipping = MoneyEntry(name: "shipping", minimum: .zero)
    static let charged = MoneyEntry(name: "amount charged", minimum: .aboveZero)
    static let rate = MoneyEntry(
        name: "rate", minimum: .aboveZero, takesCurrency: false, maximumFractionDigits: 6)

    // The amount read from the text, with the currency typed with it, or nil for an empty text.
    struct Reading: Equatable, Sendable {
        let amount: Decimal
        let currency: String?
    }

    // Reads the text. The currency is the one the amount is in when no mark is typed, and the
    // home currency names a mark such as "kr." in the region.
    func read(_ text: String, currency: String, home: String, locale: Locale)
        throws(MoneyEntryProblem) -> Reading?
    {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let first = trimmed.firstIndex(where: NumberEntry.isDigit),
            let last = trimmed.lastIndex(where: NumberEntry.isDigit)
        else { throw problem(.notANumber, currency: currency, locale: locale) }
        var prefix = String(trimmed[..<first])
        let suffix = String(trimmed[trimmed.index(after: last)...])
        var body = String(trimmed[first...last])
        if prefix.contains("-") || prefix.contains("−") {
            throw problem(.belowMinimum, currency: currency, locale: locale)
        }
        // An amount such as ".50" starts with its decimal mark.
        if let mark = prefix.last, mark == "." || mark == "," {
            body = String(mark) + body
            prefix.removeLast()
        }
        let marks = [prefix, suffix].map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard marks.count <= 1 else {
            throw problem(.notANumber, currency: currency, locale: locale)
        }
        var typedCurrency: String?
        if let mark = marks.first {
            guard takesCurrency,
                let named = CurrencyRules.currency(
                    forMark: mark, current: currency, home: home, locale: locale)
            else { throw problem(.unknownCurrency, currency: currency, locale: locale) }
            typedCurrency = named
        }
        let amountCurrency = typedCurrency ?? currency
        guard
            let digits = NumberEntry.plainDigits(
                Self.decimalBody(body, locale: locale), locale: locale),
            let amount = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX"))
        else { throw problem(.notANumber, currency: amountCurrency, locale: locale) }
        let limit = maximumFractionDigits ?? CurrencyRules.fractionDigits(of: amountCurrency)
        if Self.fractionDigits(of: digits) > limit {
            throw problem(.tooManyDecimals, currency: amountCurrency, locale: locale)
        }
        if minimum == .aboveZero, amount <= 0 {
            throw problem(.belowMinimum, currency: amountCurrency, locale: locale)
        }
        return Reading(amount: amount, currency: typedCurrency)
    }

    // What to write instead, in plain words, or nil when the text is an amount this field takes.
    func problem(in text: String, currency: String, home: String, locale: Locale) -> String? {
        do {
            _ = try read(text, currency: currency, home: home, locale: locale)
            return nil
        } catch {
            return error.message
        }
    }

    // The other of "." and "," is the decimal mark when the region's own mark is not there and
    // one or two digits end the number after it, as in "12.90" typed in Denmark.
    private static func decimalBody(_ body: String, locale: Locale) -> String {
        let decimal = locale.decimalSeparator.flatMap(\.first) ?? "."
        let other: Character = decimal == "," ? "." : ","
        guard !body.contains(decimal), body.filter({ $0 == other }).count == 1,
            let index = body.firstIndex(of: other)
        else { return body }
        let after = body[body.index(after: index)...]
        guard (1...2).contains(after.count), after.allSatisfy(NumberEntry.isDigit) else {
            return body
        }
        return body[..<index] + String(decimal) + after
    }

    // The decimals that count, so "12.900" has one.
    private static func fractionDigits(of digits: String) -> Int {
        guard let dot = digits.firstIndex(of: ".") else { return 0 }
        var fraction = digits[digits.index(after: dot)...]
        while fraction.last == "0" { fraction.removeLast() }
        return fraction.count
    }

    private func problem(
        _ kind: MoneyEntryProblem.Kind, currency: String, locale: Locale
    ) -> MoneyEntryProblem {
        let example = example(in: currency, locale: locale)
        let message: String
        switch kind {
        case .notANumber:
            message = "Enter the \(name) as a number, such as \(example)."
        case .unknownCurrency:
            message =
                takesCurrency
                ? "Enter a currency the app knows, such as £, € or GBP, or only the number."
                : "Enter only the number, such as \(example)."
        case .tooManyDecimals:
            let digits = maximumFractionDigits ?? CurrencyRules.fractionDigits(of: currency)
            message =
                digits == 0
                ? "Enter the \(name) without decimals, such as \(example)."
                : "Enter the \(name) with at most \(digits) decimals, such as \(example)."
        case .belowMinimum:
            let zero = Decimal(0).formatted(.number.locale(locale))
            message =
                minimum == .zero
                ? "Enter a \(name) of \(zero) or more." : "Enter a \(name) above \(zero)."
        }
        return MoneyEntryProblem(kind: kind, message: message)
    }

    // A typical amount in the currency, such as "12.90" or "1,290" for the yen.
    private func example(in currency: String, locale: Locale) -> String {
        if !takesCurrency {
            return Decimal(string: "1.16", locale: Locale(identifier: "en_US_POSIX"))
                .map { $0.formatted(.number.locale(locale)) } ?? "1.16"
        }
        let digits = CurrencyRules.fractionDigits(of: currency)
        let value = digits == 0 ? Decimal(1290) : Decimal(1290) / 100
        return Money(value, currency).number(locale: locale)
    }
}

nonisolated struct MoneyEntryProblem: Error, Equatable {
    enum Kind: Equatable {
        case notANumber
        case unknownCurrency
        case tooManyDecimals
        case belowMinimum
    }

    let kind: Kind
    let message: String
}
