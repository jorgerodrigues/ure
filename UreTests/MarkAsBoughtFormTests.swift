import Foundation
import Testing

@testable import Ure

struct MarkAsBoughtFormTests {
    private let britain = Locale(identifier: "en_GB")

    private func decimal(_ text: String) -> Decimal {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) ?? .nan
    }

    private func option(_ supplier: String, _ price: String?, _ currency: String?) -> PartOption {
        PartOption(
            id: UUID(), partID: UUID(), position: 0, supplier: supplier,
            url: "https://example.org/\(supplier)", price: price.map(decimal),
            currency: currency, createdAt: .now, updatedAt: .now)
    }

    @Test
    func aFieldSaysWhatToEnterOnlyOnceYouLeaveIt() {
        let form = MarkAsBoughtForm(
            options: [], rates: ExchangeRates(home: "EUR"), locale: britain)
        // Nothing is called wrong while you have not left the field.
        #expect(form.problem(for: .price) == nil)
        form.leave(.price)
        #expect(form.problem(for: .price) == "Enter the price you paid.")
        form.change(.price, to: "18,0,0")
        #expect(form.problem(for: .price) == "Enter the price as a number, such as 12.90.")
        form.change(.shipping, to: "-2")
        #expect(form.problem(for: .shipping) == nil)
        form.leave(.shipping)
        #expect(form.problem(for: .shipping) == "Enter a shipping of 0 or more.")
        form.change(.price, to: "18")
        form.change(.shipping, to: "4.50")
        #expect(form.problem(for: .price) == nil && form.problem(for: .shipping) == nil)
        #expect(form.purchase()?.paid == Money(decimal("22.5"), "EUR"))
    }

    @Test
    func markAsBoughtChecksEveryFieldAndKeepsThePopoverOpen() {
        let form = MarkAsBoughtForm(
            options: [], rates: ExchangeRates(home: "EUR"), locale: britain)
        #expect(form.purchase() == nil)
        #expect(form.problem(for: .price) == "Enter the price you paid.")
        #expect(form.problem(for: .shipping) == nil && form.problem(for: .charged) == nil)
    }

    @Test
    func typingAPoundSignSetsTheCurrencyAndAsksWhatYouWereCharged() {
        let form = MarkAsBoughtForm(
            options: [], rates: ExchangeRates(home: "EUR", rates: ["GBP": decimal("1.16")]),
            locale: britain)
        #expect(!form.asksCharged && form.currency == "EUR")
        form.change(.price, to: "£18.00")
        #expect(form.currency == "GBP" && form.price == "18.00" && form.asksCharged)
        form.change(.shipping, to: "4.50")
        // £22.50 at £1 = €1.16 is €26.10.
        #expect(form.charged == "26.10" && form.chargedHint.hasPrefix("From your rate"))
        // What you type in "Charged to you" is kept when the price changes.
        form.change(.charged, to: "26.35")
        form.change(.shipping, to: "5")
        #expect(form.charged == "26.35")
        let purchase = form.purchase()
        #expect(purchase?.price == Money(decimal("18"), "GBP"))
        #expect(purchase?.shipping == decimal("5"))
        #expect(purchase?.paid == Money(decimal("26.35"), "EUR"))
        // The menu changes the currency too. Without a rate, you type what you were charged.
        form.chooseCurrency("USD")
        #expect(form.chargedHint == "No rate for USD yet. Enter what your card was charged.")
        form.change(.charged, to: "")
        form.leave(.charged)
        #expect(form.problem(for: .charged) == "Enter what you were charged in EUR.")
        #expect(form.purchase() == nil)
    }

    @Test
    func aCurrencyTypedAfterTheNumberSetsTheCurrencyToo() {
        let form = MarkAsBoughtForm(
            options: [], rates: ExchangeRates(home: "EUR", rates: ["GBP": decimal("1.16")]),
            locale: britain)
        form.change(.price, to: "18 GBP")
        #expect(form.currency == "GBP" && form.price == "18" && form.asksCharged)
        form.change(.shipping, to: "4.50£")
        #expect(form.currency == "GBP" && form.shipping == "4.50")
        #expect(form.purchase()?.price == Money(decimal("18"), "GBP"))
        // A decimal mark at the end is still typing, not a currency.
        form.change(.price, to: "18.")
        #expect(form.price == "18." && form.currency == "GBP")
        // A decimal mark right after the currency belongs to the number.
        form.change(.price, to: "€.50")
        #expect(form.price == ".50" && form.currency == "EUR")
        #expect(form.purchase()?.price == Money(decimal("0.5"), "EUR"))
    }

    @Test
    func anOptionWithoutAPriceKeepsTheShippingItKnows() {
        var option = option("ebay.co.uk", nil, "EUR")
        option.shipping = decimal("5")
        let form = MarkAsBoughtForm(
            options: [option], rates: ExchangeRates(home: "EUR"), locale: britain)
        #expect(form.asksPrice && form.shipping == "5.00")
        form.change(.price, to: "20")
        let purchase = form.purchase()
        #expect(purchase?.shipping == decimal("5"))
        #expect(purchase?.paid == Money(decimal("25"), "EUR"))
    }

    @Test
    func whatYouWereChargedIsNeverInAnotherCurrency() {
        let form = MarkAsBoughtForm(
            options: [], rates: ExchangeRates(home: "EUR", rates: ["GBP": decimal("1.16")]),
            locale: britain)
        form.change(.price, to: "£18")
        form.change(.charged, to: "£20")
        form.leave(.charged)
        #expect(form.problem(for: .charged) == "Enter what you were charged in EUR.")
        #expect(form.purchase() == nil)
        form.change(.charged, to: "€20.90")
        #expect(form.problem(for: .charged) == nil)
        #expect(form.purchase()?.paid == Money(decimal("20.9"), "EUR"))
    }

    @Test
    func theLowestOptionIsChosenAndAnOptionWithoutAPriceAsksForOne() {
        let rates = ExchangeRates(home: "EUR", rates: ["GBP": decimal("1.16")])
        let ebay = option("eBay", "24", "EUR")
        let cousins = option("Cousins UK", "12.9", "GBP")
        let listing = option("sternkreuz.de", nil, nil)
        let form = MarkAsBoughtForm(
            options: [ebay, cousins, listing], rates: rates, locale: britain)
        #expect(form.choice == .option(cousins.id) && form.lowestID == cousins.id)
        #expect(!form.asksPrice && form.asksCharged && form.charged == "14.96")
        // A home currency option needs nothing more: what you paid is its price.
        form.choose(.option(ebay.id))
        #expect(!form.asksPrice && !form.asksCharged)
        #expect(form.purchase()?.paid == Money(decimal("24"), "EUR"))
        // An option without a price asks for one, and keeps its supplier and link.
        form.choose(.option(listing.id))
        #expect(form.asksPrice && form.supplier == "sternkreuz.de")
        form.change(.price, to: "9.90")
        let purchase = form.purchase()
        #expect(purchase?.url == listing.url && purchase?.optionID == listing.id)
        #expect(purchase?.price == Money(decimal("9.9"), "EUR"))
        // Somewhere else has no option.
        form.choose(.elsewhere)
        #expect(form.asksPrice && form.supplier.isEmpty && form.price.isEmpty)
        form.change(.price, to: "10")
        #expect(form.purchase()?.optionID == nil)
    }
}
