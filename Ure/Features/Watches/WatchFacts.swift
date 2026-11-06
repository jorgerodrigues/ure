import Foundation

// How the watch page reads and shows its dimensions.
nonisolated enum WatchNumbers {
    static let diameter = NumberEntry(
        name: "diameter", unit: "mm", units: ["mm"], minimum: .aboveZero, example: 38)
    static let lugWidth = NumberEntry(
        name: "lug width", unit: "mm", units: ["mm"], minimum: .aboveZero, example: 20)
}

// The facts on one watch's page, in reading order. The name is the page's title. Each one is
// written in place and saves on its own, as an edit on the library's queue. The caliber fact holds the caliber's ID, and its
// pop-up shows the caliber's maker and name.
struct WatchFacts {
    let name: FactField
    let brand: FactField
    let model: FactField
    let reference: FactField
    let serial: FactField
    let year: FactField
    let caliber: FactField
    let caseMaterial: FactField
    let diameter: FactField
    let lugWidth: FactField
    let owner: FactField
    let contact: FactField

    var all: [FactField] {
        [
            name, brand, model, reference, serial, year, caliber, caseMaterial, diameter, lugWidth,
            owner, contact,
        ]
    }
    // A fact holds text that has not saved, such as text the fact does not take.
    var hasUnsavedText: Bool { all.contains(where: \.hasUnsavedText) }
    // A fact holds text it does not take, such as a diameter it cannot read.
    var hasRefusedText: Bool { all.contains { $0.editor.isRefused } }

    init(
        watch: WatchRecord, queue: EditQueue, locale: Locale,
        brands: @escaping () -> [FactSuggestion],
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        let id = watch.id
        let values = Self.texts(of: watch, locale: locale)
        func text(
            _ label: String, prompt: String, actionName: String, _ value: String,
            rule: FactRule = .anyText, suggestions: @escaping () -> [FactSuggestion] = { [] },
            fact: @escaping (String) -> WatchFact
        ) -> FactField {
            FactField(
                label: label, prompt: prompt, actionName: actionName, text: value, rule: rule,
                suggestions: suggestions, queue: queue, scope: .watches,
                edit: { text in .watch(.set(id, fact(text))) }, pause: pause)
        }
        func number(
            _ label: String, prompt: String, actionName: String, _ value: String,
            entry: NumberEntry, fact: @escaping (Double?) -> WatchFact
        ) -> FactField {
            FactField(
                label: label, prompt: prompt, actionName: actionName, text: value,
                rule: .number(entry, locale: locale), queue: queue, scope: .watches,
                edit: { text in .watch(.set(id, fact(try entry.value(from: text, locale: locale))))
                }, pause: pause)
        }
        name = text(
            "Name", prompt: "Name", actionName: "Name", values.name,
            rule: .required("Enter a name."), fact: WatchFact.name)
        brand = text(
            "Brand", prompt: "Add brand", actionName: "Brand", values.brand,
            suggestions: brands, fact: WatchFact.brand)
        model = text(
            "Model", prompt: "Add model", actionName: "Model", values.model,
            fact: WatchFact.model)
        reference = text(
            "Reference", prompt: "Add reference", actionName: "Reference", values.reference,
            fact: WatchFact.reference)
        serial = text(
            "Serial", prompt: "Add serial", actionName: "Serial", values.serial,
            fact: WatchFact.serial)
        year = text(
            "Year", prompt: "Add year", actionName: "Year", values.year, fact: WatchFact.year)
        caliber = text(
            "Caliber", prompt: "Add caliber", actionName: "Caliber", values.caliber,
            fact: { WatchFact.caliber(UUID(uuidString: $0)) })
        caseMaterial = text(
            "Case", prompt: "Add case", actionName: "Case", values.caseMaterial,
            fact: WatchFact.caseMaterial)
        diameter = number(
            "Diameter", prompt: "Add diameter", actionName: "Diameter", values.diameter,
            entry: WatchNumbers.diameter, fact: WatchFact.diameter)
        lugWidth = number(
            "Lug width", prompt: "Add lug width", actionName: "Lug Width", values.lugWidth,
            entry: WatchNumbers.lugWidth, fact: WatchFact.lugWidth)
        owner = text(
            "Owner", prompt: "Add owner", actionName: "Owner", values.owner,
            fact: WatchFact.owner)
        contact = text(
            "Contact", prompt: "Add contact", actionName: "Contact", values.contact,
            fact: WatchFact.contact)
    }

    // Shows the stored values in every field that has nothing waiting to save. After Undo and
    // Redo the fields take them also while one has the cursor.
    func refresh(_ watch: WatchRecord, locale: Locale, force: Bool = false) {
        let values = Self.texts(of: watch, locale: locale)
        name.refresh(values.name, force: force)
        brand.refresh(values.brand, force: force)
        model.refresh(values.model, force: force)
        reference.refresh(values.reference, force: force)
        serial.refresh(values.serial, force: force)
        year.refresh(values.year, force: force)
        caliber.refresh(values.caliber, force: force)
        caseMaterial.refresh(values.caseMaterial, force: force)
        diameter.refresh(values.diameter, force: force)
        lugWidth.refresh(values.lugWidth, force: force)
        owner.refresh(values.owner, force: force)
        contact.refresh(values.contact, force: force)
    }

    private static func texts(of watch: WatchRecord, locale: Locale) -> WatchTexts {
        WatchTexts(
            name: watch.name, brand: watch.brand ?? "", model: watch.model ?? "",
            reference: watch.caseReference ?? "", serial: watch.serial ?? "",
            year: watch.approximateYear ?? "", caliber: watch.caliberID?.uuidString ?? "",
            caseMaterial: watch.caseMaterial ?? "",
            diameter: WatchNumbers.diameter.text(for: watch.caseDiameter, locale: locale),
            lugWidth: WatchNumbers.lugWidth.text(for: watch.lugWidth, locale: locale),
            owner: watch.owner ?? "", contact: watch.contact ?? "")
    }
}

private struct WatchTexts {
    let name: String
    let brand: String
    let model: String
    let reference: String
    let serial: String
    let year: String
    let caliber: String
    let caseMaterial: String
    let diameter: String
    let lugWidth: String
    let owner: String
    let contact: String
}
