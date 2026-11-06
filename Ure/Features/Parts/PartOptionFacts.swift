import Foundation
import Synchronization

// The facts of one buying option that you write in place on the part's page: its supplier, its
// price, its shipping and its note. Each saves on its own as you type, as an edit on the
// library's queue, with Undo. The price and the shipping show with their currency, such as
// "£12.90". Only the currency's pop-up changes the currency, as a command of its own.
struct PartOptionFacts {
    let supplier: FactField
    let price: FactField
    let shipping: FactField
    let note: FactField
    let money: PartOptionMoney
    private let locale: Locale

    var editors: [AutosaveField] { [supplier.editor, price.editor, shipping.editor, note.editor] }
    // A field holds text that has not saved, such as a price of "abc".
    var hasUnsavedText: Bool { editors.contains(where: \.hasUnsavedText) }

    init(
        option: PartOption, home: String, queue: EditQueue, locale: Locale = .current,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        let id = option.id
        let money = PartOptionMoney(option: option, home: home)
        self.money = money
        self.locale = locale
        supplier = FactField(
            label: "Supplier", prompt: "Supplier", actionName: "Supplier", text: option.supplier,
            rule: .required("Enter a supplier."), queue: queue, scope: .parts,
            edit: { .part(.setOption(id, .supplier($0))) }, pause: pause)
        price = FactField(
            label: "Price", prompt: "Price", actionName: "Price",
            text: Self.text(option.price, option.currency, locale: locale),
            rule: Self.amountRule(.price, money: money, locale: locale), queue: queue,
            scope: .parts,
            edit: { text in
                .part(.setOption(id, .price(try Self.amount(text, .price, money, locale))))
            }, pause: pause)
        shipping = FactField(
            label: "Shipping", prompt: "Shipping", actionName: "Shipping",
            text: Self.text(option.shipping, option.currency, locale: locale),
            rule: Self.amountRule(.shipping, money: money, locale: locale), queue: queue,
            scope: .parts,
            edit: { text in
                .part(.setOption(id, .shipping(try Self.amount(text, .shipping, money, locale))))
            }, pause: pause)
        note = FactField(
            label: "Note", prompt: "Add a note, such as in stock", actionName: "Note",
            text: option.note, rule: .anyText, queue: queue, scope: .parts,
            edit: { .part(.setOption(id, .note($0))) }, pause: pause)
    }

    // Shows the stored values in every field that has nothing waiting to save. After Undo and
    // Redo the fields take them also while one has the cursor.
    func refresh(_ option: PartOption, home: String, force: Bool = false) {
        money.update(option: option, home: home)
        supplier.refresh(option.supplier, force: force)
        price.refresh(Self.text(option.price, option.currency, locale: locale), force: force)
        shipping.refresh(
            Self.text(option.shipping, option.currency, locale: locale), force: force)
        note.refresh(option.note, force: force)
    }

    // The option goes, and text it never took goes with it.
    func discard() {
        for editor in editors { editor.discard() }
    }

    static func text(_ amount: Decimal?, _ currency: String?, locale: Locale) -> String {
        guard let amount, let currency else { return "" }
        return Money(amount, currency).formatted(locale: locale)
    }

    // The amount a field's text gives, or nil for an empty text. The rule has already taken the
    // text, so this only reads it.
    nonisolated static func amount(
        _ text: String, _ entry: MoneyEntry, _ money: PartOptionMoney, _ locale: Locale
    ) throws -> Decimal? {
        do throws(MoneyEntryProblem) {
            return try entry.read(text, currency: money.currency, home: money.home, locale: locale)?
                .amount
        } catch {
            throw PartValidationError(message: error.message)
        }
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

    // A currency chosen in the pop-up, which the price and the shipping read at once, before
    // its edit has saved.
    func choose(_ currency: String) {
        values.withLock { $0.currency = currency }
    }
}
