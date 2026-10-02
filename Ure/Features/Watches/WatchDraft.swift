import Foundation

nonisolated enum WatchField: String, Sendable {
    case name
    case caseDiameter
    case lugWidth
}

nonisolated struct WatchValidationError: LocalizedError {
    let fields: [WatchField: String]

    var errorDescription: String? { "Check the marked fields and try again." }
}

nonisolated struct WatchDraft: Equatable, Sendable {
    var name = ""
    var brand = ""
    var model = ""
    var caseReference = ""
    var serial = ""
    var approximateYear = ""
    var caseMaterial = ""
    var caseDiameter = ""
    var lugWidth = ""
    var waterResistance = ""
    var specificationNotes = ""

    init() {}

    init(watch: WatchRecord, locale: Locale = .current) {
        name = watch.name
        brand = watch.brand ?? ""
        model = watch.model ?? ""
        caseReference = watch.caseReference ?? ""
        serial = watch.serial ?? ""
        approximateYear = watch.approximateYear ?? ""
        caseMaterial = watch.caseMaterial ?? ""
        caseDiameter = Self.dimensionText(watch.caseDiameter, locale: locale)
        lugWidth = Self.dimensionText(watch.lugWidth, locale: locale)
        waterResistance = watch.waterResistance ?? ""
        specificationNotes = watch.specificationNotes ?? ""
    }

    func record(id: UUID, createdAt: Date, updatedAt: Date, locale: Locale) throws -> WatchRecord {
        var errors: [WatchField: String] = [:]
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { errors[.name] = "Enter a watch name." }
        let diameter = dimension(
            caseDiameter, field: .caseDiameter, locale: locale, errors: &errors)
        let width = dimension(lugWidth, field: .lugWidth, locale: locale, errors: &errors)
        guard errors.isEmpty else { throw WatchValidationError(fields: errors) }
        return WatchRecord(
            id: id, name: name, brand: optional(brand), model: optional(model),
            caseReference: optional(caseReference), serial: optional(serial),
            approximateYear: optional(approximateYear), caseMaterial: optional(caseMaterial),
            caseDiameter: diameter, lugWidth: width, waterResistance: optional(waterResistance),
            specificationNotes: optional(specificationNotes), createdAt: createdAt,
            updatedAt: updatedAt)
    }

    private func optional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return trimmed
    }

    private func dimension(
        _ text: String, field: WatchField, locale: Locale, errors: inout [WatchField: String]
    ) -> Double? {
        guard let text = optional(text) else { return nil }
        let normalized = text.replacingOccurrences(of: locale.decimalSeparator ?? ".", with: ".")
        guard let value = Double(normalized), value.isFinite, value > 0 else {
            errors[field] = "Enter a finite number greater than zero, or leave this empty."
            return nil
        }
        return value
    }

    private static func dimensionText(_ value: Double?, locale: Locale) -> String {
        guard let value else { return "" }
        return String(value).replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
    }
}
