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
        let money = MoneyState(service: MoneyService(coordinator: coordinator, region: "EUR"))
        let observation = Task { await money.observe() }
        defer { observation.cancel() }
        let service = PartService(coordinator: coordinator, region: "EUR")
        let parts = PartState(service: service, home: { money.home })
        let partsObservation = Task { await parts.observe() }
        defer { partsObservation.cancel() }

        // A rate for a currency that has none, a home currency, an option in another currency,
        // its estimate, and Mark as Bought with the amount charged.
        try await MoneyService(coordinator: coordinator, region: "EUR").setRate("1.16", for: "GBP")
        #expect(await money.setHomeCurrency("EUR"))
        let job = try await JobTaskFixture.job(coordinator)
        let part = try await service.add(named: "Mainspring", to: job.id)
        let option = try #require(
            await parts.pasteOption("https://www.cousinsuk.com/gr3807x", on: part.id))
        _ = try await service.updateOption(option.id, .currency("GBP"))
        _ = try await service.updateOption(option.id, .price("£12.90"))
        _ = try await service.updateOption(option.id, .shipping("£5.50"))
        for _ in 0..<500
        where money.rates.rates["GBP"] == nil || parts.options(of: part.id).first?.price == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let form = MarkAsBoughtForm(options: parts.options(of: part.id), rates: money.rates)
        #expect(form.estimate?.isEstimate == true)
        let purchase = try #require(form.purchase())
        #expect(await parts.markBought(purchase, of: part.id))
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
