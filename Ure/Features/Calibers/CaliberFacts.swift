import Foundation

// How the caliber page reads and shows its numbers.
nonisolated enum CaliberNumbers {
    static let beatRate = NumberEntry(
        unit: "vph", units: ["vph", "bph", "a/h"], minimum: .aboveZero, example: 28_800)
    static let jewels = NumberEntry(
        unit: nil, units: ["jewels", "jewel", "j"], minimum: .zero, example: 17)
    static let powerReserve = NumberEntry(
        unit: "h", units: ["h", "hr", "hrs", "hour", "hours"], minimum: .zero, example: 42)
    static let liftAngle = NumberEntry(
        unit: "°", joinsUnit: true, units: ["°", "deg", "degree", "degrees"],
        minimum: .aboveZero, example: 52)
}

// The facts on one caliber's page, in reading order. Each one is written in place and saves on
// its own.
struct CaliberFacts {
    let name: FactField
    let maker: FactField
    let winding: FactField
    let beatRate: FactField
    let jewels: FactField
    let powerReserve: FactField
    let liftAngle: FactField

    var all: [FactField] { [name, maker, winding, beatRate, jewels, powerReserve, liftAngle] }
    var hasUnsavedChanges: Bool { all.contains { $0.hasUnsavedChanges } }

    init(
        caliber: CaliberRecord, service: CaliberService, locale: Locale,
        makers: @escaping () -> [String],
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        let id = caliber.id
        let values = Self.texts(of: caliber, locale: locale)
        name = FactField(
            label: "Name", prompt: "Name", actionName: "Name", text: values.name,
            rule: .required("Write a name for this caliber."),
            save: { text in _ = try await service.update(id, .name(text)) }, pause: pause)
        maker = FactField(
            label: "Maker", prompt: "Add maker", actionName: "Maker", text: values.maker,
            rule: .anyText, suggestions: makers,
            save: { text in _ = try await service.update(id, .maker(text)) }, pause: pause)
        winding = FactField(
            label: "Winding", prompt: "Manual, Automatic or Quartz", actionName: "Winding",
            text: values.winding, rule: Self.windingRule,
            suggestions: { Winding.allCases.map(\.rawValue) },
            save: { text in _ = try await service.update(id, .winding(Winding(written: text))) },
            pause: pause)
        beatRate = Self.number(
            "Beat rate", prompt: "Add beat rate", actionName: "Beat Rate", text: values.beatRate,
            entry: CaliberNumbers.beatRate, locale: locale, pause: pause
        ) { value in _ = try await service.update(id, .beatRate(value)) }
        jewels = Self.number(
            "Jewels", prompt: "Add jewels", actionName: "Jewels", text: values.jewels,
            entry: CaliberNumbers.jewels, locale: locale, pause: pause
        ) { value in _ = try await service.update(id, .jewels(value)) }
        powerReserve = Self.number(
            "Power reserve", prompt: "Add power reserve", actionName: "Power Reserve",
            text: values.powerReserve, entry: CaliberNumbers.powerReserve, locale: locale,
            pause: pause
        ) { value in _ = try await service.update(id, .powerReserve(value)) }
        liftAngle = Self.number(
            "Lift angle", prompt: "Add lift angle", actionName: "Lift Angle",
            text: values.liftAngle, entry: CaliberNumbers.liftAngle, locale: locale, pause: pause
        ) { value in _ = try await service.update(id, .liftAngle(value)) }
    }

    // Shows the stored values in every field that has nothing waiting to save.
    func refresh(_ caliber: CaliberRecord, locale: Locale) {
        let values = Self.texts(of: caliber, locale: locale)
        name.refresh(values.name)
        maker.refresh(values.maker)
        winding.refresh(values.winding)
        beatRate.refresh(values.beatRate)
        jewels.refresh(values.jewels)
        powerReserve.refresh(values.powerReserve)
        liftAngle.refresh(values.liftAngle)
    }

    private static let windingRule = FactRule(
        problem: { text in
            let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty, Winding(written: typed) == nil else { return nil }
            return "Write Manual, Automatic or Quartz, or leave this empty."
        },
        normalized: { text in Winding(written: text)?.rawValue ?? "" })

    private static func number(
        _ label: String, prompt: String, actionName: String, text: String, entry: NumberEntry,
        locale: Locale, pause: @escaping (Duration) async throws -> Void,
        save: @escaping (Double?) async throws -> Void
    ) -> FactField {
        FactField(
            label: label, prompt: prompt, actionName: actionName, text: text,
            rule: .number(entry, locale: locale),
            save: { text in try await save(entry.value(from: text, locale: locale)) },
            pause: pause)
    }

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
