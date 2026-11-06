import Foundation
import Testing

@testable import Ure

nonisolated struct MoneyTests {
    private let britain = Locale(identifier: "en_GB")
    private let denmark = Locale(identifier: "da_DK")
    private let unitedStates = Locale(identifier: "en_US")

    private func decimal(_ text: String) -> Decimal {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) ?? .nan
    }

    private func read(
        _ text: String, _ entry: MoneyEntry = .price, currency: String = "EUR",
        home: String = "EUR", locale: Locale
    ) throws(MoneyEntryProblem) -> MoneyEntry.Reading? {
        try entry.read(text, currency: currency, home: home, locale: locale)
    }

    @Test
    func amountsAreReadTheWayAReceiptWritesThem() throws {
        #expect(
            try read("£12.90", locale: britain) == .init(amount: decimal("12.9"), currency: "GBP"))
        #expect(
            try read("12,90 €", locale: denmark) == .init(amount: decimal("12.9"), currency: "EUR"))
        #expect(
            try read("GBP 5.50", locale: britain) == .init(amount: decimal("5.5"), currency: "GBP"))
        #expect(
            try read("12.90 usd", locale: britain)
                == .init(amount: decimal("12.9"), currency: "USD"))
        #expect(
            try read("1.290,50", locale: denmark) == .init(amount: decimal("1290.5"), currency: nil)
        )
        #expect(
            try read("1,290", locale: unitedStates) == .init(amount: decimal("1290"), currency: nil)
        )
        #expect(
            try read(".50", locale: unitedStates) == .init(amount: decimal("0.5"), currency: nil))
        // A price copied from a shop abroad keeps its cents.
        #expect(try read("12.90", locale: denmark) == .init(amount: decimal("12.9"), currency: nil))
        #expect(
            try read("13,95", locale: unitedStates)
                == .init(amount: decimal("13.95"), currency: nil))
        // "kr." is the home currency's symbol in Denmark.
        #expect(
            try read("kr. 120", currency: "EUR", home: "DKK", locale: denmark)
                == .init(amount: decimal("120"), currency: "DKK"))
        // The amount's own currency always reads back its symbol.
        #expect(
            try read(
                Money(decimal("12.9"), "BRL").formatted(locale: denmark), currency: "BRL",
                locale: denmark)
                == .init(amount: decimal("12.9"), currency: "BRL"))
        #expect(try read("  ", locale: britain) == nil)
    }

    @Test
    func anAmountTheFieldCannotTakeSaysWhatToEnter() {
        func problem(_ text: String, _ entry: MoneyEntry = .price, currency: String = "GBP")
            -> MoneyEntryProblem.Kind?
        {
            do {
                _ = try entry.read(text, currency: currency, home: "EUR", locale: britain)
                return nil
            } catch {
                return error.kind
            }
        }
        #expect(problem("abc") == .notANumber)
        #expect(problem("12 zz") == .unknownCurrency)
        #expect(problem("£12 €") == .notANumber)
        #expect(problem("-5") == .belowMinimum)
        #expect(problem("0") == .belowMinimum)
        #expect(problem("0", .shipping) == nil)
        #expect(problem("12.905") == .tooManyDecimals)
        #expect(problem("12.900") == nil)
        #expect(problem("12.9", currency: "JPY") == .tooManyDecimals)
        #expect(problem("1.160001", .rate) == nil)
        #expect(problem("1.1600001", .rate) == .tooManyDecimals)
        #expect(problem("£1.16", .rate) == .unknownCurrency)
        #expect(
            MoneyEntry.price.problem(in: "12.905", currency: "GBP", home: "EUR", locale: britain)
                == "Enter the price with at most 2 decimals, such as 12.90.")
        #expect(
            MoneyEntry.shipping.problem(in: "abc", currency: "EUR", home: "EUR", locale: denmark)
                == "Enter the shipping as a number, such as 12,90.")
        #expect(
            MoneyEntry.price.problem(in: "0", currency: "EUR", home: "EUR", locale: britain)
                == "Enter a price above 0.")
    }

    @Test
    func moneyAddsUpExactlyAndRoundsToTheCurrencysCents() {
        // Floating point would make 0.1 + 0.2 come to 0.30000000000000004.
        #expect(decimal("0.1") + decimal("0.2") == decimal("0.3"))
        #expect(
            PartOption(
                id: UUID(), partID: UUID(), position: 0, supplier: "Cousins UK",
                url: "https://x.uk",
                price: decimal("12.9"), shipping: decimal("5.5"), currency: "GBP", createdAt: .now,
                updatedAt: .now
            ).total == Money(decimal("18.4"), "GBP"))
        // Halves round away from zero, to the cents of the currency.
        #expect(CurrencyRules.rounded(decimal("21.345"), to: "EUR") == decimal("21.35"))
        #expect(CurrencyRules.rounded(decimal("21.344"), to: "EUR") == decimal("21.34"))
        #expect(CurrencyRules.rounded(decimal("1290.5"), to: "JPY") == decimal("1291"))
        #expect(CurrencyRules.rounded(decimal("1.2345"), to: "KWD") == decimal("1.235"))
        #expect(CurrencyRules.fractionDigits(of: "EUR") == 2)
        #expect(CurrencyRules.fractionDigits(of: "JPY") == 0)
        // Money shows in the region's format.
        #expect(Money(decimal("21.4"), "EUR").formatted(locale: britain) == "€21.40")
        #expect(Money(decimal("21.4"), "EUR").formatted(locale: denmark) == "21,40\u{A0}€")
    }

    @Test
    func anEstimateNeedsARateAndTheHomeCurrencyNeedsNone() {
        let rates = ExchangeRates(home: "EUR", rates: ["GBP": decimal("1.16")])
        // £12.90 + £5.50 at £1 = €1.16 is €21.344, shown as ≈ €21.34.
        let pounds = rates.inHome(Money(decimal("18.4"), "GBP"))
        #expect(pounds == HomeAmount(money: Money(decimal("21.34"), "EUR"), isEstimate: true))
        #expect(pounds?.formatted(locale: britain) == "≈ €21.34")
        // A price in the home currency is itself, with no ≈.
        let euros = rates.inHome(Money(decimal("24"), "EUR"))
        #expect(euros == HomeAmount(money: Money(decimal("24"), "EUR"), isEstimate: false))
        #expect(euros?.formatted(locale: britain) == "€24.00")
        // Without a rate there is no estimate.
        #expect(rates.inHome(Money(decimal("30.45"), "USD")) == nil)
        // A rate is for one home currency.
        let settings = MoneySettings(
            homeCurrency: nil,
            rates: [
                CurrencyRateRecord(
                    homeCurrency: "EUR", currency: "GBP", rate: decimal("1.16"), updatedAt: .now),
                CurrencyRateRecord(
                    homeCurrency: "DKK", currency: "GBP", rate: decimal("8.65"), updatedAt: .now),
            ])
        #expect(
            settings.exchangeRates(region: "DKK")
                == ExchangeRates(home: "DKK", rates: ["GBP": decimal("8.65")]))
        var chosen = settings
        chosen.homeCurrency = "EUR"
        #expect(chosen.exchangeRates(region: "DKK").rates == ["GBP": decimal("1.16")])
        #expect(CurrencyRules.regionCurrency(Locale(identifier: "da_DK")) == "DKK")
        #expect(CurrencyRules.regionCurrency(Locale(identifier: "en_GB")) == "GBP")
    }

    @Test
    func theLowestOptionIsTheLowestPriceWithShippingInTheHomeCurrency() {
        let rates = ExchangeRates(home: "EUR", rates: ["GBP": decimal("1.16")])
        func option(_ supplier: String, _ price: String?, _ shipping: String?, _ currency: String?)
            -> PartOption
        {
            PartOption(
                id: UUID(), partID: UUID(), position: 0, supplier: supplier,
                url: "https://example.org",
                price: price.map(decimal), shipping: shipping.map(decimal), currency: currency,
                createdAt: .now, updatedAt: .now)
        }
        let cousins = option("Cousins UK", "12.9", "5.5", "GBP")
        let ebay = option("eBay", "24", "0", "EUR")
        let esslinger = option("Esslinger", "13.95", "16.5", "USD")
        let unpriced = option("example.org", nil, nil, nil)
        let options = [ebay, cousins, esslinger, unpriced]
        // €21.34 beats €24.00. The dollar option has no rate, so it is not compared.
        #expect(PartPricing.lowest(options, rates: rates) == cousins.id)
        #expect(
            PartPricing.lowestPrice(options, rates: rates)
                == HomeAmount(money: Money(decimal("21.34"), "EUR"), isEstimate: true))
        // One option that can be compared is not marked Lowest.
        #expect(PartPricing.lowest([ebay, esslinger], rates: rates) == nil)
        // Of two equal ones, the first wins.
        let twin = option("Twin", "24", "0", "EUR")
        #expect(PartPricing.lowest([ebay, twin], rates: rates) == ebay.id)
        #expect(PartMoneyWording.headline(of: cousins, rates: rates, locale: britain) == "≈ €21.34")
        #expect(
            PartMoneyWording.headline(of: esslinger, rates: rates, locale: britain) == "US$30.45")
        #expect(
            PartMoneyWording.breakdown(of: cousins, rates: rates, locale: britain)
                == "£12.90 + £5.50 shipping")
        #expect(
            PartMoneyWording.breakdown(of: ebay, rates: rates, locale: britain) == "free shipping")
        #expect(
            PartMoneyWording.breakdown(of: unpriced, rates: rates, locale: britain)
                == "No price yet")
        #expect(
            PartMoneyWording.keptOptions([ebay, esslinger], rates: rates, locale: britain)
                == "2 other options kept · eBay €24.00, Esslinger US$30.45")
    }

    @Test
    func aJobsPaidTotalAddsOnlyWhatYouWereCharged() {
        func part(paid: String?, currency: String = "EUR", price: String = "12.9") -> PartRecord {
            var record = PartRecord(
                id: UUID(), jobID: UUID(), position: 0, name: "Part", stage: .ordered,
                createdAt: .now, updatedAt: .now)
            if let paid {
                record.purchase = PartPurchase(
                    supplier: "Cousins UK", url: nil, optionID: nil,
                    price: Money(decimal(price), "GBP"), shipping: decimal("5.5"),
                    paid: Money(decimal(paid), currency))
            }
            return record
        }
        let parts = [
            part(paid: "21.4"), part(paid: "6.4"), part(paid: nil), part(paid: "14.6"),
            part(paid: "120", currency: "DKK"),
        ]
        // The shops' prices in pounds never count. An amount paid in an earlier home currency
        // shows after the home currency's total.
        let totals = PartPricing.paid(parts, home: "EUR")
        #expect(totals == [Money(decimal("42.4"), "EUR"), Money(decimal("120"), "DKK")])
        #expect(PartMoneyWording.paid([totals[0]], locale: britain) == "€42.40 paid")
        #expect(
            PartMoneyWording.paid(totals, locale: britain) == "€42.40 + DKK\u{A0}120.00 paid")
        #expect(PartMoneyWording.paid([], locale: britain) == nil)
    }
}
