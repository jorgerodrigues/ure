import Foundation

nonisolated enum CaliberField: String, Sendable {
    case designation
    case beatRate
    case jewelCount
    case powerReserve
    case liftAngle
}

nonisolated struct CaliberValidationError: LocalizedError {
    let fields: [CaliberField: String]

    var errorDescription: String? { "Check the marked fields and try again." }
}

nonisolated struct CaliberDraft: Equatable, Sendable {
    var designation = ""
    var manufacturer = ""
    var variant = ""
    var movementType = MovementType.unknown
    var beatRate = ""
    var jewelCount = ""
    var powerReserve = ""
    var liftAngle = ""
    var specificationNotes = ""
    var sourceNote = ""

    init() {}

    init(caliber: CaliberRecord, locale: Locale = .current) {
        designation = caliber.designation
        manufacturer = caliber.manufacturer ?? ""
        variant = caliber.variant ?? ""
        movementType = caliber.movementType
        beatRate = Self.numberText(caliber.beatRate, locale: locale)
        jewelCount = Self.numberText(caliber.jewelCount, locale: locale)
        powerReserve = Self.numberText(caliber.powerReserve, locale: locale)
        liftAngle = Self.numberText(caliber.liftAngle, locale: locale)
        specificationNotes = caliber.specificationNotes ?? ""
        sourceNote = caliber.sourceNote ?? ""
    }

    func record(id: UUID, createdAt: Date, updatedAt: Date, locale: Locale) throws -> CaliberRecord
    {
        var errors: [CaliberField: String] = [:]
        let designation = designation.trimmingCharacters(in: .whitespacesAndNewlines)
        if designation.isEmpty { errors[.designation] = "Enter a caliber designation." }
        let beatRate = number(beatRate, field: .beatRate, locale: locale, errors: &errors)
        let jewelCount = number(jewelCount, field: .jewelCount, locale: locale, errors: &errors)
        let powerReserve = number(
            powerReserve, field: .powerReserve, locale: locale, errors: &errors)
        let liftAngle = number(liftAngle, field: .liftAngle, locale: locale, errors: &errors)
        guard errors.isEmpty else { throw CaliberValidationError(fields: errors) }
        return CaliberRecord(
            id: id, designation: designation, manufacturer: optional(manufacturer),
            variant: optional(variant), movementType: movementType, beatRate: beatRate,
            jewelCount: jewelCount, powerReserve: powerReserve, liftAngle: liftAngle,
            specificationNotes: optional(specificationNotes), sourceNote: optional(sourceNote),
            createdAt: createdAt, updatedAt: updatedAt)
    }

    private func optional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return trimmed
    }

    private func number(
        _ text: String, field: CaliberField, locale: Locale, errors: inout [CaliberField: String]
    ) -> Double? {
        guard let text = optional(text) else { return nil }
        let normalized = text.replacingOccurrences(of: locale.decimalSeparator ?? ".", with: ".")
        let requiresPositive = field == .beatRate || field == .liftAngle
        guard let value = Double(normalized), value.isFinite, value >= 0,
            !requiresPositive || value > 0
        else {
            if requiresPositive {
                errors[field] = "Enter a finite number greater than zero, or leave this empty."
            } else {
                errors[field] = "Enter a finite number of zero or more, or leave this empty."
            }
            return nil
        }
        return value
    }

    private static func numberText(_ value: Double?, locale: Locale) -> String {
        guard let value else { return "" }
        return String(value).replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
    }
}
