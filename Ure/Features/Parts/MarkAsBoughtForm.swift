import Foundation
import Observation

// What the Mark as Bought popover holds while it is open, as on the "3c Mark as bought"
// artboard. You pick one of the part's options or "Somewhere else". The lowest option is picked
// for you. An option without a price, Somewhere else, and a part with no options ask for the
// supplier, the price with its currency and the shipping. Only the price is needed, and typing
// £ or $ sets its currency. When you pay in another currency, "Charged to you" asks for the real
// amount in your home currency, filled in from your rate. A field says what to enter once you
// leave it, and Mark as Bought checks every field. Cancel changes nothing.
@Observable
final class MarkAsBoughtForm {
    enum Choice: Hashable {
        case option(UUID)
        case elsewhere
    }

    enum Field: Hashable {
        case supplier
        case price
        case shipping
        case charged
    }

    let options: [PartOption]
    let rates: ExchangeRates
    @ObservationIgnored private let locale: Locale
    private(set) var choice: Choice
    private(set) var supplier = ""
    private(set) var price = ""
    private(set) var shipping = ""
    private(set) var charged = ""
    // The currency of a price you type.
    private(set) var currency: String
    // The fields focus has left, which say what to enter from then on.
    private(set) var leftFields: Set<Field> = []
    // Once you type what you were charged, the estimate no longer replaces it.
    @ObservationIgnored private var typedCharged = false

    init(options: [PartOption], rates: ExchangeRates, locale: Locale = .current) {
        self.options = options
        self.rates = rates
        self.locale = locale
        currency = rates.home
        if let lowest = PartPricing.lowest(options, rates: rates) {
            choice = .option(lowest)
        } else if let first = options.first(where: { $0.total != nil }) ?? options.first {
            choice = .option(first.id)
        } else {
            choice = .elsewhere
        }
        prepareChoice()
    }

    var lowestID: UUID? { PartPricing.lowest(options, rates: rates) }

    var chosenOption: PartOption? {
        guard case .option(let id) = choice else { return nil }
        return options.first { $0.id == id }
    }

    // Somewhere else, or an option without a price, asks for the price.
    var asksPrice: Bool { chosenOption?.total == nil }

    // The currency the price is in: the chosen option's, or the one you typed or chose.
    var priceCurrency: String {
        if !asksPrice, let currency = chosenOption?.currency { return currency }
        return currency
    }

    // "Charged to you" shows only when you pay in another currency.
    var asksCharged: Bool { priceCurrency != rates.home }

    // The estimate in the home currency of what you pay, or nil without a rate.
    var estimate: HomeAmount? { total.flatMap(rates.inHome) }

    // What the line beside "Charged to you" says.
    var chargedHint: String {
        if estimate != nil { return "From your rate. Match it to your card statement." }
        return "No rate for \(priceCurrency) yet. Enter what your card was charged."
    }

    func choose(_ choice: Choice) {
        guard choice != self.choice else { return }
        self.choice = choice
        leftFields = []
        typedCharged = false
        prepareChoice()
    }

    func change(_ field: Field, to text: String) {
        switch field {
        case .supplier:
            supplier = text
        case .price:
            price = takingCurrency(from: text)
        case .shipping:
            shipping = takingCurrency(from: text)
        case .charged:
            charged = text
            typedCharged = true
        }
        if field != .charged { fillCharged() }
    }

    // The currency's pop-up beside the price.
    func chooseCurrency(_ code: String) {
        guard CurrencyRules.isKnown(code), code != currency else { return }
        currency = code
        fillCharged()
    }

    func leave(_ field: Field) { leftFields.insert(field) }

    // What to enter in a field, once focus has left it.
    func problem(for field: Field) -> String? {
        guard leftFields.contains(field) else { return nil }
        return check(field)
    }

    // What was bought, or nil when a field still needs something. Every field then says what
    // to enter.
    func purchase() -> PartPurchase? {
        leftFields = [.supplier, .price, .shipping, .charged]
        guard [Field.price, .shipping, .charged].allSatisfy({ check($0) == nil }),
            let total
        else { return nil }
        let option = chosenOption
        let paid: Money
        if asksCharged {
            guard let amount = readCharged() else { return nil }
            paid = Money(amount, rates.home)
        } else {
            paid = Money(total.amount, rates.home)
        }
        if !asksPrice, let option, let price = option.price, let currency = option.currency {
            return PartPurchase(
                supplier: option.supplier, url: option.url, optionID: option.id,
                price: Money(price, currency), shipping: option.shipping, paid: paid)
        }
        guard let price = read(price, as: .price) else { return nil }
        let typed = supplier.trimmingCharacters(in: .whitespacesAndNewlines)
        return PartPurchase(
            supplier: typed.isEmpty ? nil : typed, url: option?.url, optionID: option?.id,
            price: Money(price, currency), shipping: read(shipping, as: .shipping), paid: paid)
    }

    // The price with its shipping, in the price's currency, or nil while there is no price.
    private var total: Money? {
        if !asksPrice { return chosenOption?.total }
        guard let price = read(price, as: .price) else { return nil }
        return Money(price + (read(shipping, as: .shipping) ?? 0), currency)
    }

    private func check(_ field: Field) -> String? {
        switch field {
        case .supplier:
            return nil
        case .price:
            guard asksPrice else { return nil }
            if price.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Enter the price you paid."
            }
            return MoneyEntry.price.problem(
                in: price, currency: currency, home: rates.home, locale: locale)
        case .shipping:
            guard asksPrice else { return nil }
            return MoneyEntry.shipping.problem(
                in: shipping, currency: currency, home: rates.home, locale: locale)
        case .charged:
            guard asksCharged else { return nil }
            let message = "Enter what you were charged in \(rates.home)."
            if charged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return message }
            do throws(MoneyEntryProblem) {
                // What you were charged is in the home currency, so another currency typed
                // with it is never relabelled.
                let reading = try MoneyEntry.charged.read(
                    charged, currency: rates.home, home: rates.home, locale: locale)
                if let typed = reading?.currency, typed != rates.home { return message }
                return nil
            } catch {
                return error.message
            }
        }
    }

    private func read(_ text: String, as entry: MoneyEntry) -> Decimal? {
        (try? entry.read(text, currency: currency, home: rates.home, locale: locale))?.amount
    }

    private func readCharged() -> Decimal? {
        (try? MoneyEntry.charged.read(
            charged, currency: rates.home, home: rates.home, locale: locale))?.amount
    }

    // A currency mark typed before or after an amount, such as "£18.00" or "18 GBP", sets the
    // currency, and the field keeps only the number.
    private func takingCurrency(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let isMark = { (character: Character) in
            !NumberEntry.isDigit(character) && !character.isWhitespace
        }
        var leading = String(trimmed.prefix(while: isMark))
        // A decimal mark right before the digits belongs to the number, as in "£.50".
        if let last = leading.last, last == "." || last == ",",
            trimmed.dropFirst(leading.count).first.map(NumberEntry.isDigit) == true
        {
            leading.removeLast()
        }
        let trailing = String(String(trimmed.reversed()).prefix(while: isMark).reversed())
        if let named = named(leading) {
            currency = named
            return String(trimmed.dropFirst(leading.count)).trimmingCharacters(in: .whitespaces)
        }
        if leading.count < trimmed.count, let named = named(trailing) {
            currency = named
            return String(trimmed.dropLast(trailing.count)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    // The currency a typed mark names, or nil for no mark or a decimal mark.
    private func named(_ mark: String) -> String? {
        guard !mark.isEmpty, mark != ".", mark != "," else { return nil }
        return CurrencyRules.currency(
            forMark: mark, current: currency, home: rates.home, locale: locale)
    }

    // A new choice starts from its own values: an option without a price offers its supplier,
    // and the amount charged starts from the estimate.
    private func prepareChoice() {
        supplier = chosenOption?.supplier ?? ""
        price = ""
        currency = chosenOption?.currency ?? rates.home
        // An option without a price may know its shipping already, which counts in what you
        // paid.
        shipping = chosenOption?.shipping.map { Money($0, currency).number(locale: locale) } ?? ""
        charged = ""
        fillCharged()
    }

    private func fillCharged() {
        guard !typedCharged else { return }
        charged = estimate.map { $0.money.number(locale: locale) } ?? ""
    }
}
