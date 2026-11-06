import AppKit
import Foundation
import GRDB
import Testing

@testable import Ure

struct PartBuyingTests {
    private func decimal(_ text: String) -> Decimal {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) ?? .nan
    }

    private func setUp(_ fixture: WatchFixture, clock: PartClock = PartClock()) async throws
        -> (LibraryCoordinator, JobRecord, PartService, PartState, Task<Void, Never>)
    {
        let coordinator = fixture.coordinator(dependencies: LibraryDependencies(now: clock.now))
        _ = try await coordinator.open()
        // The library's own home currency, so the queue's services and the fields agree on it
        // whatever the Mac's region is.
        try await MoneyService(coordinator: coordinator).setHomeCurrency("EUR")
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(
            coordinator: coordinator, region: "EUR", locale: Locale(identifier: "en_GB"))
        let parts = PartState(
            service: service, queue: EditQueue(coordinator: coordinator), home: { "EUR" })
        let observation = Task { await parts.observe() }
        try await waitUntil { !parts.isLoading }
        return (coordinator, job, service, parts, observation)
    }

    @Test(.timeLimit(.minutes(1)))
    func aPastedLinkAddsAnOptionAndUndoTakesItAway() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let (coordinator, job, service, parts, observation) = try await setUp(fixture)
        defer { observation.cancel() }
        let part = try await service.add(named: "Mainspring", to: job.id)
        try await waitUntil { parts.part(part.id) != nil }
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        // Text that is not a link adds nothing and says so.
        #expect(parts.pasteOption("Cousins UK", on: part.id, undoManager: undoManager) == nil)
        #expect(parts.optionError == LinkError.notALink.errorDescription)
        #expect(parts.options(of: part.id).isEmpty && !undoManager.canUndo)

        undoManager.beginUndoGrouping()
        let pasted = parts.pasteOption(
            "https://www.cousinsuk.com/product/gr3807x", on: part.id, undoManager: undoManager)
        undoManager.endUndoGrouping()
        let option = try #require(await pasted?.option)
        #expect(option.supplier == "cousinsuk.com" && option.price == nil)
        #expect(parts.openOptionID == option.id && parts.priceToFocus == option.id)
        #expect(undoManager.undoActionName == PartState.addOptionActionName)
        let second = try #require(
            await parts.pasteOption("https://www.ebay.co.uk/itm/1", on: part.id)?.option)
        #expect(parts.options(of: part.id).map(\.id) == [option.id, second.id])

        undoManager.undo()
        await parts.queue.waitUntilIdle()
        #expect(
            try await coordinator.read { try PartQueries.options(of: part.id, in: $0) }.map(\.id)
                == [second.id])
        #expect(parts.options(of: part.id).map(\.id) == [second.id])
        undoManager.redo()
        await parts.queue.waitUntilIdle()
        #expect(parts.options(of: part.id).map(\.id) == [option.id, second.id])
        #expect(try await coordinator.read { try PartQueries.option(option.id, in: $0) } == option)
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func anOptionsPriceAndShippingAreTypedAsOnAReceipt() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let (coordinator, job, service, parts, observation) = try await setUp(fixture)
        defer { observation.cancel() }
        let part = try await service.add(named: "Mainspring", to: job.id)
        let option = try await service.addOption(
            try #require(URL(string: "https://www.cousinsuk.com/gr3807x")), to: part.id)

        // A first amount is in the home currency, and the currency's pop-up changes it.
        var saved = try await service.updateOption(option.id, .price(decimal("24"))).after
        #expect(saved.price == decimal("24") && saved.currency == "EUR")
        saved = try await service.updateOption(option.id, .currency("GBP")).after
        saved = try await service.updateOption(option.id, .price(decimal("12.9"))).after
        #expect(saved.price == decimal("12.9") && saved.currency == "GBP")
        saved = try await service.updateOption(option.id, .shipping(decimal("5.5"))).after
        saved = try await service.updateOption(option.id, .supplier("  Cousins UK ")).after
        let noted = try await service.updateOption(option.id, .note("GR 3807X · in stock"))
        saved = noted.after
        #expect(saved.supplier == "Cousins UK" && saved.note == "GR 3807X · in stock")
        #expect(saved.total == Money(decimal("18.4"), "GBP"))
        // A note's Undo puts back the stored note.
        #expect(PartOptionFact.note("x").stored(in: noted.before) == .note(""))
        // A value the option does not take is refused, and the option keeps its last one.
        await #expect(throws: PartValidationError.self) {
            _ = try await service.updateOption(option.id, .price(decimal("12.905")))
        }
        await #expect(throws: PartValidationError.self) {
            _ = try await service.updateOption(option.id, .price(0))
        }
        await #expect(throws: PartValidationError.self) {
            _ = try await service.updateOption(option.id, .supplier(" "))
        }
        await #expect(throws: PartError.unknownCurrency) {
            _ = try await service.updateOption(option.id, .currency("XYZ"))
        }
        #expect(try await coordinator.read { try PartQueries.option(option.id, in: $0) } == saved)

        // The fields show the stored amount with its currency, and a typed price saves with Undo.
        try await waitUntil { parts.facts(forOption: option.id)?.price.text == "£12.90" }
        let facts = try #require(parts.facts(forOption: option.id))
        #expect(facts.shipping.text == "£5.50" && parts.option(option.id)?.currency == "GBP")
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        facts.price.beginEditing()
        undoManager.beginUndoGrouping()
        facts.price.change(to: "20", undoManager: undoManager)
        undoManager.endUndoGrouping()
        facts.price.endEditing()
        await parts.queue.waitUntilIdle()
        #expect(facts.price.text == "£20.00")
        saved = try #require(
            try await coordinator.read { try PartQueries.option(option.id, in: $0) })
        #expect(saved.price == decimal("20") && saved.currency == "GBP")
        // Undo puts back the price as it was.
        undoManager.undo()
        await parts.queue.waitUntilIdle()
        #expect(facts.price.text == "£12.90")
        saved = try #require(
            try await coordinator.read { try PartQueries.option(option.id, in: $0) })
        #expect(saved.price == decimal("12.9") && saved.currency == "GBP")
        // A price the field cannot take stays on screen and never saves.
        facts.price.beginEditing()
        facts.price.change(to: "abc", undoManager: nil)
        facts.price.endEditing()
        #expect(facts.price.problem == "Enter the price as a number, such as 12.90.")
        await parts.queue.waitUntilIdle()
        #expect(
            try await coordinator.read { try PartQueries.option(option.id, in: $0) }?.price
                == decimal("12.9"))
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func markAsBoughtFromAnOptionOrdersThePartAndUndoPutsItBack() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let clock = PartClock()
        let (coordinator, job, service, parts, observation) = try await setUp(fixture, clock: clock)
        defer { observation.cancel() }
        let part = try await service.add(named: "Mainspring", to: job.id)
        let cousins = try await service.addOption(
            try #require(URL(string: "https://cousinsuk.com/gr3807x")), to: part.id)
        _ = try await service.updateOption(cousins.id, .currency("GBP"))
        _ = try await service.updateOption(cousins.id, .price(decimal("12.9")))
        _ = try await service.updateOption(cousins.id, .shipping(decimal("5.5")))
        let ebay = try await service.addOption(
            try #require(URL(string: "https://ebay.co.uk/itm/1")), to: part.id)
        _ = try await service.updateOption(ebay.id, .price(decimal("24")))
        try await waitUntil { parts.options(of: part.id).count == 2 }

        let rates = ExchangeRates(home: "EUR", rates: ["GBP": decimal("1.16")])
        let form = MarkAsBoughtForm(
            options: parts.options(of: part.id), rates: rates, locale: Locale(identifier: "en_GB"))
        // The lowest option is chosen for you, and what you were charged starts from the rate.
        #expect(form.choice == .option(cousins.id) && form.asksCharged && !form.asksPrice)
        #expect(form.charged == "21.34")
        form.change(.charged, to: "21.40")
        let purchase = try #require(form.purchase())
        #expect(purchase.supplier == "cousinsuk.com" && purchase.optionID == cousins.id)
        #expect(purchase.price == Money(decimal("12.9"), "GBP"))
        #expect(purchase.shipping == decimal("5.5"))
        #expect(purchase.paid == Money(decimal("21.4"), "EUR"))

        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        clock.set(5_000)
        undoManager.beginUndoGrouping()
        let bought = parts.markBought(purchase, of: part.id, undoManager: undoManager)
        undoManager.endUndoGrouping()
        #expect(await bought.didSave)
        #expect(undoManager.undoActionName == PartState.buyActionName)
        var saved = try await stored(part.id, coordinator)
        #expect(saved.stage == .ordered && saved.orderedAt == clock.date(5_000))
        #expect(saved.purchase == purchase && saved.boughtURL == "https://cousinsuk.com/gr3807x")
        #expect(parts.part(part.id)?.purchase == purchase)
        // Every option is kept.
        #expect(
            try await coordinator.read { try PartQueries.options(of: part.id, in: $0) }.count == 2)
        #expect(PartWording.days(of: saved, now: clock.date(5_000)) == "Bought today")

        undoManager.undo()
        await parts.queue.waitUntilIdle()
        saved = try await stored(part.id, coordinator)
        #expect(saved.stage == .needed && saved.orderedAt == nil && saved.purchase == nil)
        #expect(parts.part(part.id)?.purchase == nil)
        undoManager.redo()
        await parts.queue.waitUntilIdle()
        saved = try await stored(part.id, coordinator)
        #expect(saved.stage == .ordered && saved.purchase == purchase)
        #expect(saved.orderedAt == clock.date(5_000))

        // Moving it on keeps what was bought. Back to Needed, it is to buy again, and Undo puts
        // back what was bought.
        #expect(await parts.advance(part.id).didSave)
        #expect(try await stored(part.id, coordinator).purchase == purchase)
        undoManager.beginUndoGrouping()
        let needed = parts.setStage(.needed, of: part.id, undoManager: undoManager)
        undoManager.endUndoGrouping()
        #expect(await needed.didSave)
        saved = try await stored(part.id, coordinator)
        #expect(saved.stage == .needed && saved.purchase == nil)
        undoManager.undo()
        await parts.queue.waitUntilIdle()
        saved = try await stored(part.id, coordinator)
        #expect(saved.stage == .inHand && saved.purchase == purchase)
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func markAsBoughtFromJustAnAmountRecordsWhatYouPaid() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let (coordinator, job, service, parts, observation) = try await setUp(fixture)
        defer { observation.cancel() }
        let part = try await service.add(named: "Crystal gasket", to: job.id)
        try await waitUntil { parts.part(part.id) != nil }
        let form = MarkAsBoughtForm(
            options: [], rates: ExchangeRates(home: "EUR"), locale: Locale(identifier: "en_GB"))
        #expect(form.choice == .elsewhere && form.asksPrice && !form.asksCharged)
        form.change(.supplier, to: "eBay, watchparts_uk")
        form.change(.price, to: "6.40")
        let purchase = try #require(form.purchase())
        #expect(purchase.paid == Money(decimal("6.4"), "EUR") && purchase.shipping == nil)
        #expect(await parts.markBought(purchase, of: part.id).didSave)
        var saved = try await stored(part.id, coordinator)
        #expect(saved.stage == .ordered && saved.purchase?.supplier == "eBay, watchparts_uk")

        // A spare in hand keeps its state when you record what you paid for it.
        let spare = try await service.add(named: "Crystal, 29.5 mm", to: nil)
        try await waitUntil { parts.part(spare.id) != nil }
        #expect(await parts.markBought(purchase, of: spare.id).didSave)
        saved = try await stored(spare.id, coordinator)
        #expect(saved.stage == .inHand && saved.orderedAt == nil && saved.purchase == purchase)

        // A purchase the app cannot keep is refused.
        var broken = purchase
        broken.paid = Money(0, "EUR")
        await #expect(throws: PartError.invalidPurchase) {
            _ = try await service.markBought(part.id, broken)
        }
        broken.paid = Money(1, "XYZ")
        await #expect(throws: PartError.unknownCurrency) {
            _ = try await service.markBought(part.id, broken)
        }
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aDeletedPartOrOptionComesBackWithWhatWasBought() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let (coordinator, job, service, parts, observation) = try await setUp(fixture)
        defer { observation.cancel() }
        let part = try await service.add(named: "Crown", to: job.id)
        let option = try await service.addOption(
            try #require(URL(string: "https://esslinger.com/crowns")), to: part.id)
        _ = try await service.updateOption(option.id, .currency("USD"))
        let priced = try await service.updateOption(option.id, .price(decimal("13.95"))).after
        let purchase = PartPurchase(
            supplier: "Esslinger", url: option.url, optionID: option.id,
            price: Money(decimal("13.95"), "USD"), shipping: nil,
            paid: Money(decimal("12.85"), "EUR"))
        _ = try await service.markBought(part.id, purchase)
        try await waitUntil { parts.part(part.id)?.purchase == purchase }
        let bought = try await stored(part.id, coordinator)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        undoManager.beginUndoGrouping()
        let removed = parts.remove(part.id, undoManager: undoManager)
        undoManager.endUndoGrouping()
        #expect(await removed.didSave)
        #expect(try await coordinator.read { try PartQueries.options(of: part.id, in: $0) }.isEmpty)
        #expect(parts.options(of: part.id).isEmpty && parts.facts(forOption: option.id) == nil)
        undoManager.undo()
        await parts.queue.waitUntilIdle()
        #expect(parts.options(of: part.id) == [priced])
        #expect(try await stored(part.id, coordinator) == bought)

        undoManager.beginUndoGrouping()
        let gone = parts.removeOption(option.id, undoManager: undoManager)
        undoManager.endUndoGrouping()
        #expect(await gone.didSave)
        #expect(undoManager.undoActionName == PartState.removeOptionActionName)
        #expect(try await coordinator.read { try PartQueries.option(option.id, in: $0) } == nil)
        undoManager.undo()
        await parts.queue.waitUntilIdle()
        #expect(try await coordinator.read { try PartQueries.option(option.id, in: $0) } == priced)
        #expect(parts.options(of: part.id) == [priced])
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func anOptionTakesNoEditsWhileItsDeletionSavesAndItsUndoComesFromTheStoredData()
        async throws
    {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let (coordinator, job, service, parts, observation) = try await setUp(fixture)
        defer { observation.cancel() }
        let part = try await service.add(named: "Crown", to: job.id)
        let option = try await service.addOption(
            try #require(URL(string: "https://esslinger.com/crowns")), to: part.id)
        try await waitUntil { parts.facts(forOption: option.id) != nil }
        let facts = try #require(parts.facts(forOption: option.id))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        // A first price in the home currency, typed and saved before the option goes.
        undoManager.beginUndoGrouping()
        facts.price.beginEditing()
        facts.price.change(to: "€30", undoManager: undoManager)
        undoManager.endUndoGrouping()
        facts.price.endEditing()

        // While the deletion saves, the option takes no edits, and its part can't be marked
        // bought with it.
        let (hold, holding) = try await LibraryHold.start(on: coordinator)
        undoManager.beginUndoGrouping()
        let gone = parts.removeOption(option.id, undoManager: undoManager)
        undoManager.endUndoGrouping()
        let waiting = try #require(parts.option(option.id))
        #expect(gone != nil && !parts.canEdit(waiting))
        #expect(parts.chooseCurrency("GBP", of: option.id) == nil)
        #expect(parts.removeOption(option.id) == nil)
        hold.release()
        _ = try await holding.value
        #expect(await gone.didSave)
        #expect(parts.option(option.id) == nil)

        // Undo brings the option back with its price. Undo of the price then comes from the
        // stored data, because the field that took it went with the option, and it leaves the
        // option with no price and no currency of its own, as it was.
        undoManager.undo()
        await parts.queue.waitUntilIdle()
        #expect(parts.option(option.id)?.price == decimal("30"))
        undoManager.undo()
        await parts.queue.waitUntilIdle()
        let undone = try #require(
            try await coordinator.read { try PartQueries.option(option.id, in: $0) })
        #expect(undone.price == nil && undone.currency == nil)
        #expect(parts.facts(forOption: option.id)?.price.text == "")
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func theHomeCurrencyComesFromTheRegionAndRatesAreYoursToSet() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let service = MoneyService(
            coordinator: coordinator, region: "DKK", locale: Locale(identifier: "da_DK"))
        let money = MoneyState(service: service, queue: EditQueue(coordinator: coordinator))
        let observation = Task { await money.observe() }
        defer { observation.cancel() }
        try await waitUntil { !money.isLoading }
        #expect(money.home == "DKK" && money.isHomeFromRegion && money.rates.rates.isEmpty)

        // A rate is above 0, and none takes it away.
        _ = try await service.setRate(decimal("8.65"), for: "GBP", home: "DKK")
        try await waitUntil { money.rates.rates["GBP"] == decimal("8.65") }
        await #expect(throws: PartValidationError.self) {
            _ = try await service.setRate(0, for: "GBP", home: "DKK")
        }
        #expect(money.rates.rates["GBP"] == decimal("8.65"))
        // Choosing another home currency shows its own rates, and choosing back finds them again.
        #expect(await money.setHomeCurrency("EUR").saved)
        try await waitUntil { money.home == "EUR" }
        #expect(money.rates.rates.isEmpty && !money.isHomeFromRegion)
        _ = try await service.setRate(decimal("1.16"), for: "GBP", home: "EUR")
        try await waitUntil { money.rates.rates["GBP"] == decimal("1.16") }
        #expect(await money.setHomeCurrency(nil).saved)
        try await waitUntil { money.home == "DKK" }
        #expect(money.rates.rates == ["GBP": decimal("8.65")])
        _ = try await service.setRate(nil, for: "GBP", home: "DKK")
        try await waitUntil { money.rates.rates.isEmpty }
        // The field in Settings reads the rate as typed on paper, and saves it as you type.
        let field = money.rateField(for: "USD")
        #expect(field.label == "US$1 =")
        field.beginEditing()
        field.change(to: "abc", undoManager: nil)
        field.endEditing()
        #expect(field.problem != nil)
        field.beginEditing()
        field.change(to: "6,9", undoManager: nil)
        field.endEditing()
        await money.queue.waitUntilIdle()
        try await waitUntil { money.rates.rates["USD"] == decimal("6.9") }
        #expect(money.rateCurrencies == ["USD"])
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func anOptionsCurrencyNeverRelabelsAnAmountAndUndoPutsItBack() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let (coordinator, job, service, parts, observation) = try await setUp(fixture)
        defer { observation.cancel() }
        let part = try await service.add(named: "Mainspring", to: job.id)
        let option = try await service.addOption(
            try #require(URL(string: "https://cousinsuk.com/gr3807x")), to: part.id)

        // A price typed in pounds on an option in euros is refused, so typing never changes the
        // currency.
        _ = try await service.updateOption(option.id, .shipping(decimal("5")))
        try await waitUntil { parts.facts(forOption: option.id)?.shipping.text == "€5.00" }
        let facts = try #require(parts.facts(forOption: option.id))
        facts.price.beginEditing()
        facts.price.change(to: "£10", undoManager: nil)
        facts.price.endEditing()
        #expect(
            facts.price.problem == "Choose GBP in the currency menu first. This option is in EUR.")
        facts.price.beginEditing()
        facts.price.change(to: "", undoManager: nil)
        facts.price.endEditing()
        await parts.queue.waitUntilIdle()
        #expect(parts.option(option.id)?.currency == "EUR")

        // A currency that can't take an amount is refused at once: 12.90 has no place in yen.
        _ = try await service.updateOption(option.id, .price(decimal("12.9")))
        try await waitUntil { facts.price.text == "€12.90" }
        #expect(parts.chooseCurrency("JPY", of: option.id) == nil)
        #expect(parts.optionError == PartOptionRules.tooPrecise(for: "JPY"))
        await #expect(throws: PartValidationError.self) {
            _ = try await service.updateOption(option.id, .currency("JPY"))
        }
        // A currency that takes them keeps the numbers, and the price then reads in it.
        #expect(await parts.chooseCurrency("GBP", of: option.id).didSave)
        #expect(parts.option(option.id)?.price == decimal("12.9"))
        #expect(facts.price.text == "£12.90")

        // A price refused for its mark saves once you choose that currency, as the field asks,
        // so Mark as Bought offers it.
        let typedFirst = try await service.addOption(
            try #require(URL(string: "https://cousinsuk.com/gr3808x")), to: part.id)
        try await waitUntil { parts.facts(forOption: typedFirst.id) != nil }
        let typedFacts = try #require(parts.facts(forOption: typedFirst.id))
        typedFacts.price.beginEditing()
        typedFacts.price.change(to: "£10", undoManager: nil)
        typedFacts.price.endEditing()
        #expect(typedFacts.price.problem != nil)
        #expect(await parts.chooseCurrency("GBP", of: typedFirst.id).didSave)
        await parts.queue.waitUntilIdle()
        let corrected = try #require(
            try await coordinator.read { try PartQueries.option(typedFirst.id, in: $0) })
        #expect(corrected.price == decimal("10") && corrected.currency == "GBP")
        #expect(typedFacts.price.problem == nil && typedFacts.price.text == "£10.00")
        #expect(await parts.savedOptions(of: part.id)?.contains(corrected) == true)

        // A first choice of currency undoes to none, which is the home currency.
        let fresh = try await service.addOption(
            try #require(URL(string: "https://ebay.co.uk/itm/1")), to: part.id)
        try await waitUntil { parts.facts(forOption: fresh.id) != nil }
        let freshFacts = try #require(parts.facts(forOption: fresh.id))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        let chosen = parts.chooseCurrency("GBP", of: fresh.id, undoManager: undoManager)
        undoManager.endUndoGrouping()
        #expect(await chosen.didSave)
        #expect(undoManager.undoActionName == PartState.currencyActionName)
        undoManager.undo()
        await parts.queue.waitUntilIdle()
        #expect(
            try await coordinator.read { try PartQueries.option(fresh.id, in: $0) }?.currency == nil
        )

        // Undo of a first price leaves the option with no currency of its own, as it was, so a
        // later price follows the home currency.
        undoManager.beginUndoGrouping()
        freshFacts.price.beginEditing()
        freshFacts.price.change(to: "€12", undoManager: undoManager)
        undoManager.endUndoGrouping()
        freshFacts.price.endEditing()
        await parts.queue.waitUntilIdle()
        #expect(parts.option(fresh.id)?.currency == "EUR")
        undoManager.undo()
        await parts.queue.waitUntilIdle()
        let emptied = try #require(
            try await coordinator.read { try PartQueries.option(fresh.id, in: $0) })
        #expect(emptied.price == nil && emptied.currency == nil)
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func markAsBoughtOffersThePriceJustTypedAndWaitsBehindAFailedSave() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let (coordinator, job, service, parts, observation) = try await setUp(fixture)
        defer { observation.cancel() }
        let part = try await service.add(named: "Mainspring", to: job.id)
        let option = try await service.addOption(
            try #require(URL(string: "https://cousinsuk.com/gr3807x")), to: part.id)
        try await waitUntil { parts.facts(forOption: option.id) != nil }
        let facts = try #require(parts.facts(forOption: option.id))
        // The price is still being typed when Mark as Bought opens.
        facts.price.beginEditing()
        facts.price.change(to: "€30", undoManager: nil)
        let options = try #require(await parts.savedOptions(of: part.id))
        #expect(options.first?.price == decimal("30") && options.first?.currency == "EUR")
        facts.price.endEditing()

        // A price that did not save stops Mark as Bought, so it never offers the old price.
        // Try Again saves it, and then it is offered.
        try await JobTaskFixture.failWrites(coordinator, on: "partOption")
        facts.price.beginEditing()
        facts.price.change(to: "€40", undoManager: nil)
        #expect(await parts.savedOptions(of: part.id) == nil)
        #expect(parts.queue.isStopped)
        try await JobTaskFixture.allowWrites(coordinator, on: "partOption")
        parts.queue.retry()
        #expect(await parts.savedOptions(of: part.id)?.first?.price == decimal("40"))
        facts.price.endEditing()

        // A price the field does not take stops it too.
        facts.price.beginEditing()
        facts.price.change(to: "abc", undoManager: nil)
        #expect(await parts.savedOptions(of: part.id) == nil)
        facts.price.change(to: "€40", undoManager: nil)
        facts.price.endEditing()

        // A purchase whose save fails stops the queue with the part as it was, and Try Again
        // saves it.
        let form = MarkAsBoughtForm(options: options, rates: ExchangeRates(home: "EUR"))
        let purchase = try #require(form.purchase())
        try await JobTaskFixture.failWrites(coordinator, on: "part")
        let bought = parts.markBought(purchase, of: part.id)
        #expect(await parts.queue.waitUntilStopped())
        #expect(parts.queue.failure != nil && bought?.isPending == true)
        #expect(try await stored(part.id, coordinator).purchase == nil)
        try await JobTaskFixture.allowWrites(coordinator, on: "part")
        parts.queue.retry()
        #expect(await bought.didSave)
        #expect(try await stored(part.id, coordinator).purchase == purchase)
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aRateFieldsUndoStaysWithItsHomeCurrency() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let money = MoneyState(
            service: MoneyService(
                coordinator: coordinator, region: "EUR", locale: Locale(identifier: "en_GB")),
            queue: EditQueue(coordinator: coordinator))
        let observation = Task { await money.observe() }
        defer { observation.cancel() }
        try await waitUntil { !money.isLoading }
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let euros = money.rateField(for: "GBP")
        euros.beginEditing()
        undoManager.beginUndoGrouping()
        euros.change(to: "1.16", undoManager: undoManager)
        undoManager.endUndoGrouping()
        euros.endEditing()
        try await waitUntil { money.rates.rates["GBP"] == decimal("1.16") }
        // In Danish kroner, the pound has a rate of its own, and the parts hear of the change.
        var changes = 0
        money.homeChanged = { changes += 1 }
        #expect(await money.setHomeCurrency("DKK").saved)
        try await waitUntil { money.home == "DKK" }
        #expect(changes == 1)
        _ = try await MoneyService(coordinator: coordinator).setRate(
            decimal("8.65"), for: "GBP", home: "DKK")
        try await waitUntil { money.rates.rates["GBP"] == decimal("8.65") }
        // Undo of the rate typed for euros takes away the euro rate, not the krone's.
        undoManager.undo()
        await money.queue.waitUntilIdle()
        let rates = try await coordinator.read(MoneyQueries.settings).rates
        #expect(
            rates.map(\.homeCurrency) == ["DKK"] && rates.first?.rate == decimal("8.65"),
            "\(rates.map { "\($0.homeCurrency) \($0.currency) \($0.rate)" })")
        // Redo puts the euro rate back.
        undoManager.redo()
        await money.queue.waitUntilIdle()
        #expect(
            try await coordinator.read { try MoneyQueries.rate(of: "GBP", home: "EUR", in: $0) }
                == decimal("1.16"))
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func anOptionWithoutACurrencyFollowsANewHomeCurrency() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let job = try await JobTaskFixture.job(coordinator)
        let service = PartService(
            coordinator: coordinator, region: "JPY", locale: Locale(identifier: "en_GB"))
        let session = HomeCurrency("JPY")
        let parts = PartState(
            service: service, queue: EditQueue(coordinator: coordinator),
            home: { session.code })
        let observation = Task { await parts.observe() }
        defer { observation.cancel() }
        let part = try await service.add(named: "Mainspring", to: job.id)
        let option = try await service.addOption(
            try #require(URL(string: "https://cousinsuk.com/gr3807x")), to: part.id)
        try await waitUntil { parts.facts(forOption: option.id) != nil }
        let facts = try #require(parts.facts(forOption: option.id))
        // In yen, 12.50 has too many decimals.
        facts.price.beginEditing()
        facts.price.change(to: "12.50", undoManager: nil)
        facts.price.endEditing()
        #expect(facts.price.problem != nil)
        // Once the home currency is the euro, the same text is a price, and it saves without
        // being typed again.
        try await MoneyService(coordinator: coordinator).setHomeCurrency("EUR")
        session.code = "EUR"
        parts.homeCurrencyChanged()
        #expect(facts.price.problem == nil)
        await parts.queue.waitUntilIdle()
        let saved = try await coordinator.read { try PartQueries.option(option.id, in: $0) }
        #expect(saved?.price == decimal("12.5") && saved?.currency == "EUR")
        try await coordinator.close()
    }

    @Test
    func aSessionLetsGoOfItsPartsAndMoneyWhenItGoes() {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        var session: WorkshopSession? = WorkshopSession(
            coordinator: fixture.coordinator(),
            configuration: AppConfiguration(libraryRoot: fixture.root))
        weak let parts = session?.parts
        weak let money = session?.money
        #expect(parts != nil && money != nil)
        // A restore replaces the session, and the old library's states must not stay behind.
        session = nil
        #expect(parts == nil && money == nil)
    }

    private func stored(_ id: UUID, _ coordinator: LibraryCoordinator) async throws -> PartRecord {
        try #require(try await coordinator.read { try PartQueries.fetch(id, in: $0) })
    }
}

extension EditTicket {
    // The option an edit added or changed, once it has run.
    fileprivate var option: PartOption? {
        get async {
            for case .partOption(let option) in await value.changes { return option }
            return nil
        }
    }
}

// The home currency a test changes, as Settings does.
private final class HomeCurrency {
    var code: String

    init(_ code: String) { self.code = code }
}

private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw BuyingTimeout()
}

nonisolated private struct BuyingTimeout: Error {}
