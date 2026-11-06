import Foundation

// How the caliber page reads and shows its numbers.
nonisolated enum CaliberNumbers {
    static let beatRate = NumberEntry(
        name: "beat rate", unit: "vph", units: ["vph", "bph", "a/h"], minimum: .aboveZero,
        example: 28_800)
    static let jewels = NumberEntry(
        name: "jewel count", unit: nil, units: ["jewels", "jewel", "j"], minimum: .zero,
        example: 17)
    static let powerReserve = NumberEntry(
        name: "power reserve", unit: "h", units: ["h", "hr", "hrs", "hour", "hours"],
        minimum: .zero, example: 42)
    static let liftAngle = NumberEntry(
        name: "lift angle", unit: "°", joinsUnit: true, units: ["°", "deg", "degree", "degrees"],
        minimum: .aboveZero, example: 52)
}

// The facts on one caliber's page, in reading order. The name is the page's title. Each one is
// written in place and saves on its own, as an edit on the library's queue.
struct CaliberFacts {
    let name: FactField
    let maker: FactField
    let winding: FactField
    let beatRate: FactField
    let jewels: FactField
    let powerReserve: FactField
    let liftAngle: FactField

    var all: [FactField] { [name, maker, winding, beatRate, jewels, powerReserve, liftAngle] }
    // A fact holds text that has not saved, such as text the fact does not take.
    var hasUnsavedText: Bool { all.contains(where: \.hasUnsavedText) }
    // A fact holds text it does not take, such as a beat rate it cannot read.
    var hasRefusedText: Bool { all.contains { $0.editor.isRefused } }

    // Tries text whose save failed once more.
    func saveFailedText() {
        for field in all { field.editor.saveFailedText() }
    }

    init(
        caliber: CaliberRecord, queue: EditQueue, locale: Locale,
        makers: @escaping () -> [FactSuggestion],
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        let id = caliber.id
        let values = Self.texts(of: caliber, locale: locale)
        func fact(
            _ label: String, prompt: String, actionName: String, _ text: String,
            rule: FactRule, suggestions: @escaping () -> [FactSuggestion] = { [] },
            _ fact: @escaping (String) throws -> CaliberFact
        ) -> FactField {
            FactField(
                label: label, prompt: prompt, actionName: actionName, text: text, rule: rule,
                suggestions: suggestions, queue: queue, scope: .calibers,
                edit: { text in .caliber(.set(id, try fact(text))) }, pause: pause)
        }
        func number(
            _ label: String, prompt: String, actionName: String, _ text: String,
            entry: NumberEntry, _ make: @escaping (Double?) -> CaliberFact
        ) -> FactField {
            fact(
                label, prompt: prompt, actionName: actionName, text,
                rule: .number(entry, locale: locale)
            ) { text in make(try entry.value(from: text, locale: locale)) }
        }
        name = fact(
            "Name", prompt: "Name", actionName: "Name", values.name,
            rule: .required("Enter a name."), CaliberFact.name)
        maker = fact(
            "Maker", prompt: "Add maker", actionName: "Maker", values.maker, rule: .anyText,
            suggestions: makers, CaliberFact.maker)
        winding = fact(
            "Winding", prompt: "Add winding", actionName: "Winding", values.winding,
            rule: Self.windingRule
        ) { text in .winding(Winding(written: text)) }
        beatRate = number(
            "Beat rate", prompt: "Add beat rate", actionName: "Beat Rate", values.beatRate,
            entry: CaliberNumbers.beatRate, CaliberFact.beatRate)
        jewels = number(
            "Jewels", prompt: "Add jewels", actionName: "Jewels", values.jewels,
            entry: CaliberNumbers.jewels, CaliberFact.jewels)
        powerReserve = number(
            "Power reserve", prompt: "Add power reserve", actionName: "Power Reserve",
            values.powerReserve, entry: CaliberNumbers.powerReserve, CaliberFact.powerReserve)
        liftAngle = number(
            "Lift angle", prompt: "Add lift angle", actionName: "Lift Angle", values.liftAngle,
            entry: CaliberNumbers.liftAngle, CaliberFact.liftAngle)
    }

    // Shows the stored values in every field that has nothing waiting to save. After Undo and
    // Redo the fields take them also while one has the cursor.
    func refresh(_ caliber: CaliberRecord, locale: Locale, force: Bool = false) {
        let values = Self.texts(of: caliber, locale: locale)
        name.refresh(values.name, force: force)
        maker.refresh(values.maker, force: force)
        winding.refresh(values.winding, force: force)
        beatRate.refresh(values.beatRate, force: force)
        jewels.refresh(values.jewels, force: force)
        powerReserve.refresh(values.powerReserve, force: force)
        liftAngle.refresh(values.liftAngle, force: force)
    }

    private static let windingRule = FactRule(
        problem: { text in
            let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty, Winding(written: typed) == nil else { return nil }
            return "Choose Manual, Automatic or Quartz."
        },
        normalized: { text in Winding(written: text)?.rawValue ?? "" })

    private static func texts(of caliber: CaliberRecord, locale: Locale) -> CaliberTexts {
        CaliberTexts(
            name: caliber.designation, maker: caliber.manufacturer ?? "",
            winding: caliber.winding?.rawValue ?? "",
            beatRate: CaliberNumbers.beatRate.text(for: caliber.beatRate, locale: locale),
            jewels: CaliberNumbers.jewels.text(for: caliber.jewelCount, locale: locale),
            powerReserve: CaliberNumbers.powerReserve.text(
                for: caliber.powerReserve, locale: locale),
            liftAngle: CaliberNumbers.liftAngle.text(for: caliber.liftAngle, locale: locale))
    }
}

private struct CaliberTexts {
    let name: String
    let maker: String
    let winding: String
    let beatRate: String
    let jewels: String
    let powerReserve: String
    let liftAngle: String
}
