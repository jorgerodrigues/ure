import Foundation
import Synchronization

// The facts of one buying option that you write in place on the part's page: its supplier, its
// price, its shipping, its currency and its note. Each saves on its own as you type, with Undo.
// The price and the shipping show with their currency, such as "£12.90". Only the currency's
// pop-up changes the currency.
struct PartOptionFacts {
    let supplier: FactField
    let price: FactField
    let shipping: FactField
    let currency: FactField
    let note: FactField
    let money: PartOptionMoney

    var editors: [AutosaveField] {
        [supplier.editor, price.editor, shipping.editor, currency.editor, note.editor]
    }
    var hasUnsavedChanges: Bool { editors.contains { $0.hasUnsavedChanges } }

    init(
        option: PartOption, home: String, service: PartService, locale: Locale = .current,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        let id = option.id
        let money = PartOptionMoney(option: option, home: home)
        self.money = money
        supplier = FactField(
            label: "Supplier", prompt: "Supplier", actionName: "Supplier", text: option.supplier,
            rule: .required("Enter a supplier."),
            save: { text in _ = try await service.updateOption(id, .supplier(text)) },
            pause: pause)
        price = FactField(
            label: "Price", prompt: "Price", actionName: "Price",
            text: Self.text(option.price, option.currency, locale: locale),
            rule: Self.amountRule(.price, money: money, locale: locale),
            save: { text in _ = try await service.updateOption(id, .price(text)) }, pause: pause)
        shipping = FactField(
            label: "Shipping", prompt: "Shipping", actionName: "Shipping",
            text: Self.text(option.shipping, option.currency, locale: locale),
            rule: Self.amountRule(.shipping, money: money, locale: locale),
            save: { text in _ = try await service.updateOption(id, .shipping(text)) },
            pause: pause)
        currency = FactField(
            label: "Currency", prompt: home, actionName: "Currency",
            text: option.currency ?? "", rule: .anyText,
            save: { code in _ = try await service.updateOption(id, .currency(code)) },
            pause: pause)
        note = FactField(
            label: "Note", prompt: "Add a note, such as in stock", actionName: "Note",
            text: option.note, rule: .anyText,
            save: { text in _ = try await service.updateOption(id, .note(text)) }, pause: pause)
    }

    // Shows the stored values in every field that has nothing waiting to save.
    func refresh(_ option: PartOption, home: String, locale: Locale = .current) {
        money.update(option: option, home: home)
        supplier.refresh(option.supplier)
        price.refresh(Self.text(option.price, option.currency, locale: locale))
        shipping.refresh(Self.text(option.shipping, option.currency, locale: locale))
        currency.refresh(option.currency ?? "")
        note.refresh(option.note)
    }

    static func text(_ amount: Decimal?, _ currency: String?, locale: Locale) -> String {
        guard let amount, let currency else { return "" }
        return Money(amount, currency).formatted(locale: locale)
    }

    // An amount typed as on a receipt, in the option's currency, which a mark typed with it
    // must be. Once saved it shows with its currency, such as "£12.90".
    static func amountRule(_ entry: MoneyEntry, money: PartOptionMoney, locale: Locale)
        -> FactRule
    {
        FactRule(
            problem: { text in
                do throws(MoneyEntryProblem) {
                    let reading = try entry.read(
                        text, currency: money.currency, home: money.home, locale: locale)
                    return PartOptionRules.conflict(
                        typed: reading?.currency, current: money.currency)
                } catch {
                    return error.message
                }
            },
            normalized: { text in
                guard
                    let reading = try? entry.read(
                        text, currency: money.currency, home: money.home, locale: locale)
                else { return text }
                return Money(reading.amount, reading.currency ?? money.currency)
                    .formatted(locale: locale)
            })
    }
}

// The currency an option's amounts are in and the home currency, which its price and
// shipping fields read while you type. The fields' rules may run on any task, so a lock keeps
// them.
nonisolated final class PartOptionMoney: Sendable {
    private struct Values {
        var currency: String
        var home: String
    }

    private let values: Mutex<Values>

    init(option: PartOption, home: String) {
        values = Mutex(Values(currency: option.currency ?? home, home: home))
    }

    var currency: String { values.withLock { $0.currency } }
    var home: String { values.withLock { $0.home } }

    func update(option: PartOption, home: String) {
        values.withLock { $0 = Values(currency: option.currency ?? home, home: home) }
    }
}
