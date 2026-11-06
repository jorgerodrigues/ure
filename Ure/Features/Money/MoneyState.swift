import Foundation
import GRDB
import Observation

// Your home currency and the exchange rates you set. The home currency comes from the Mac's
// region until you choose another in Settings. Each rate is one unit of a currency in the home
// currency, such as £1 = €1.16. You type it once, it saves as you type, and the app never fetches
// one online. Prices in a currency without a rate show no estimate.
@Observable
final class MoneyState {
    private let service: MoneyService
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    private(set) var settings = MoneySettings()
    private(set) var isLoading = true
    private(set) var loadError: String?
    private(set) var saveError: String?
    // Currencies you added in Settings that have no rate yet, so their row shows.
    private(set) var addedCurrencies: Set<String> = []
    @ObservationIgnored private var rateFields: [RateKey: FactField] = [:]
    // Called when the home currency changes, so the parts' fields read amounts in it.
    @ObservationIgnored var homeChanged: () -> Void = {}

    init(
        service: MoneyService,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.service = service
        self.pause = pause
    }

    var region: String { service.region }
    var home: String { settings.home(region: region) }
    var rates: ExchangeRates { settings.exchangeRates(region: region) }
    var isHomeFromRegion: Bool { settings.homeCurrency == nil }

    // The currencies Settings shows a rate for: those the library's prices are in, those with a
    // rate for the home currency and those you added, in order of code.
    var rateCurrencies: [String] {
        let rated = settings.rates.filter { $0.homeCurrency == home }.map(\.currency)
        return Set(settings.usedCurrencies + rated + addedCurrencies)
            .subtracting([home]).sorted()
    }

    // The field where you type a currency's rate in the home currency, made the first time it
    // is asked for.
    func rateField(for currency: String) -> FactField {
        let key = RateKey(home: home, currency: currency)
        if let field = rateFields[key] { return field }
        let service = service
        let field = FactField(
            label: "\(CurrencyRules.symbol(of: currency, locale: service.locale))1 =",
            prompt: "No rate",
            actionName: "Exchange Rate", text: rateText(for: currency),
            rule: Self.rateRule(locale: service.locale),
            save: { text in try await service.setRate(text, for: currency, home: key.home) },
            pause: pause)
        rateFields[key] = field
        return field
    }

    var hasUnsavedFacts: Bool { rateFields.values.contains { $0.hasUnsavedChanges } }

    func saveFactsNow() {
        for field in rateFields.values where field.hasUnsavedChanges { field.saveNow() }
    }

    func saveAllFacts() async -> Bool {
        var succeeded = true
        for field in rateFields.values where field.hasUnsavedChanges {
            if await !field.flush() { succeeded = false }
        }
        return succeeded
    }

    func discardUndo() {
        for field in rateFields.values { field.discardUndo() }
    }

    func observe() async {
        isLoading = true
        loadError = nil
        do {
            let values = try await service.coordinator.moneyValues()
            for try await settings in values {
                let previousHome = home
                self.settings = settings
                if home != previousHome { homeChanged() }
                for (key, field) in rateFields where key.home == home {
                    field.refresh(rateText(for: key.currency))
                }
                isLoading = false
            }
        } catch {
            if Task.isCancelled { return }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    func setHomeCurrencyCommand(_ code: String?) { Task { await setHomeCurrency(code) } }

    // Chooses the home currency, or nil to follow the Mac's region again. Prices you already
    // paid keep the currency they were paid in.
    @discardableResult
    func setHomeCurrency(_ code: String?) async -> Bool {
        saveError = nil
        do {
            try await service.setHomeCurrency(code)
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    // Shows a row for a currency, so you can type its rate.
    func addCurrency(_ code: String) {
        guard CurrencyRules.isKnown(code), code != home else { return }
        addedCurrencies.insert(code)
    }

    private func rateText(for currency: String) -> String {
        guard let rate = rates.rates[currency] else { return "" }
        return rate.formatted(.number.locale(service.locale).precision(.fractionLength(0...6)))
    }

    private static func rateRule(locale: Locale) -> FactRule {
        FactRule(
            problem: { text in
                MoneyEntry.rate.problem(in: text, currency: "EUR", home: "EUR", locale: locale)
            },
            normalized: { text in
                guard
                    let reading = try? MoneyEntry.rate.read(
                        text, currency: "EUR", home: "EUR", locale: locale)
                else { return text }
                return reading.amount.formatted(
                    .number.locale(locale).precision(.fractionLength(0...6)))
            })
    }

    private struct RateKey: Hashable {
        let home: String
        let currency: String
    }
}
