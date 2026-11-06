import SwiftUI

// The home currency and the exchange rates in Settings. The home currency comes from the Mac's
// region until you choose another. Each rate is typed once, such as £1 = €1.16, and saves as
// you type. The app never fetches a rate online.
struct MoneySettingsSection: View {
    @Environment(MoneyState.self) private var money

    var body: some View {
        Section("Money") {
            Picker("Home currency", selection: Binding(get: homeChoice, set: chooseHome)) {
                Text("From the Mac’s region · \(money.region)").tag(String?.none)
                Divider()
                ForEach(CurrencyRules.codes, id: \.self) { code in
                    Text(CurrencyMenuItems.title(of: code)).tag(String?.some(code))
                }
            }
            .accessibilityIdentifier("homeCurrency")
            ForEach(money.rateCurrencies, id: \.self) { currency in
                ExchangeRateRow(currency: currency, field: money.rateField(for: currency))
            }
            Menu("Add a Rate") {
                CurrencyMenuItems(first: [], choose: money.addCurrency)
            }
            .fixedSize()
            .accessibilityIdentifier("addRate")
            if let error = money.refusal ?? money.loadError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            Text(
                "Type each rate once, such as £1 = €1.16. Ure never fetches rates online. A price in a currency without a rate shows no estimate, and what you paid stays in the currency you paid in."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func homeChoice() -> String? { money.settings.homeCurrency }
    private func chooseHome(_ code: String?) { money.setHomeCurrencyCommand(code) }
}

// The Money section while a restore replaces the library. It takes no edits then, because they
// would go to the library that is being replaced.
struct MoneySettingsDuringRestore: View {
    var body: some View {
        Section("Money") {
            Text("The home currency and the rates come back when the restore finishes.")
                .foregroundStyle(.secondary)
        }
    }
}

// One rate, such as "British Pound  £1 = [1.16] €". A blank rate is no rate.
private struct ExchangeRateRow: View {
    @Environment(MoneyState.self) private var money
    let currency: String
    let field: FactField

    var body: some View {
        LabeledContent(CurrencyMenuItems.title(of: currency)) {
            HStack(spacing: 6) {
                Text(field.label).foregroundStyle(.secondary)
                InPlaceField(
                    field: field, isEditable: true, identifier: "rate-\(currency)",
                    showsHint: false
                )
                .frame(width: 120)
                Text(CurrencyRules.symbol(of: money.home)).foregroundStyle(.secondary)
            }
        }
    }
}
