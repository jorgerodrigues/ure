import Foundation
import Security
import Synchronization
import Testing

@testable import Ure

// The user decided on 4 November 2026 that exchange rates are typed once per currency and never
// fetched online. These tests fail if the app could reach the network, or asks for anything
// online while it works with rates, estimates and what was paid.
struct NoNetworkRatesTests {
    @Test
    func theAppHasNoNetworkEntitlement() throws {
        let task = try #require(SecTaskCreateFromSelf(nil))
        for entitlement in [
            "com.apple.security.network.client", "com.apple.security.network.server",
        ] {
            let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil)
            #expect(value == nil, "\(entitlement)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func settingRatesAndMarkingAPartBoughtMakeNoNetworkRequest() async throws {
        RecordingURLProtocol.start()
        defer { RecordingURLProtocol.stop() }
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let queue = EditQueue(coordinator: coordinator)
        let money = MoneyState(
            service: MoneyService(
                coordinator: coordinator, region: "EUR", locale: Locale(identifier: "en_GB")),
            queue: queue)
        let observation = Task { await money.observe() }
        defer { observation.cancel() }
        let service = PartService(coordinator: coordinator, region: "EUR")
        let parts = PartState(service: service, queue: queue, home: { money.home })
        let partsObservation = Task { await parts.observe() }
        defer { partsObservation.cancel() }

        // A home currency, a rate typed for a currency that has none, an option in another
        // currency, its estimate, and Mark as Bought with the amount charged.
        #expect(await money.setHomeCurrency("EUR").saved)
        let rate = money.rateField(for: "GBP")
        rate.beginEditing()
        rate.change(to: "1.16", undoManager: nil)
        rate.endEditing()
        let job = try await JobTaskFixture.job(coordinator)
        let part = try await service.add(named: "Mainspring", to: job.id)
        for _ in 0..<500 where parts.part(part.id) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await parts.pasteOption("https://www.cousinsuk.com/gr3807x", on: part.id).didSave)
        let option = try #require(parts.options(of: part.id).first)
        _ = try await service.updateOption(option.id, .currency("GBP"))
        _ = try await service.updateOption(option.id, .price(Decimal(string: "12.9")))
        _ = try await service.updateOption(option.id, .shipping(Decimal(string: "5.5")))
        for _ in 0..<500
        where money.rates.rates["GBP"] == nil || parts.options(of: part.id).first?.price == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let form = MarkAsBoughtForm(options: parts.options(of: part.id), rates: money.rates)
        #expect(form.estimate?.isEstimate == true)
        let purchase = try #require(form.purchase())
        #expect(await parts.markBought(purchase, of: part.id).didSave)
        #expect(
            ExchangeRates(home: "EUR").inHome(Money(1, "USD")) == nil,
            "A currency without a rate has no estimate, rather than one fetched online.")

        #expect(RecordingURLProtocol.requests.isEmpty)
        try await coordinator.close()
    }
}

// Records every URL request the app's URL loading would make, and loads none.
nonisolated final class RecordingURLProtocol: URLProtocol {
    private static let recorded = Mutex<[String]>([])

    static var requests: [String] { recorded.withLock { $0 } }

    static func start() {
        recorded.withLock { $0 = [] }
        URLProtocol.registerClass(RecordingURLProtocol.self)
    }

    static func stop() { URLProtocol.unregisterClass(RecordingURLProtocol.self) }

    override class func canInit(with request: URLRequest) -> Bool {
        recorded.withLock { $0.append(request.url?.absoluteString ?? "a request") }
        return false
    }
}
