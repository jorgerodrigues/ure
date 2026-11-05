import Foundation

// A number typed into a fact field, read the way you would write it on paper: "35", "35mm" or
// "35,0 mm". The region's decimal mark separates the fraction. Spaces, the region's grouping
// mark and the other of "." and "," can group thousands, and each group after the first has
// three digits. A unit after the number must be one the field knows. Everything else is not a
// number yet. Numbers show in the region format with the field's unit.
nonisolated struct NumberEntry: Sendable {
    enum Minimum: Sendable {
        case zero
        case aboveZero
    }

    // The unit written after a shown number, such as "vph". Nil shows the bare number.
    let unit: String?
    // Whether the unit follows the number without a space, as in "52°".
    var joinsUnit = false
    // Units a typed number may end with, in lowercase.
    let units: Set<String>
    let minimum: Minimum
    // A typical value, used in the message that explains what to write.
    let example: Double

    func text(for value: Double?, locale: Locale) -> String {
        guard let value else { return "" }
        let number = value.formatted(.number.locale(locale).precision(.fractionLength(0...6)))
        guard let unit else { return number }
        return joinsUnit ? number + unit : "\(number) \(unit)"
    }

    func value(from text: String, locale: Locale) throws(NumberEntryProblem) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let first = trimmed.first, first == "-" || first == "−" {
            throw problem(.belowMinimum, locale: locale)
        }
        let decimal = locale.decimalSeparator.flatMap(\.first) ?? "."
        let groupMarks = groupingMarks(locale: locale, decimal: decimal)
        let numberEnd =
            trimmed.firstIndex { character in
                !Self.isDigit(character) && character != decimal
                    && !groupMarks.contains(character) && !character.isWhitespace
            } ?? trimmed.endIndex
        let number = trimmed[..<numberEnd].trimmingCharacters(in: .whitespaces)
        let unit = trimmed[numberEnd...].trimmingCharacters(in: .whitespaces).lowercased()
        guard !number.isEmpty,
            let digits = Self.digits(number, decimal: decimal, groups: groupMarks)
        else { throw problem(.notANumber, locale: locale) }
        guard unit.isEmpty || units.contains(Self.withoutTrailingDot(unit)) else {
            throw problem(.unknownUnit, locale: locale)
        }
        guard let value = Double(digits), value.isFinite else {
            throw problem(.notANumber, locale: locale)
        }
        if minimum == .aboveZero, value <= 0 { throw problem(.belowMinimum, locale: locale) }
        return value
    }

    // What to write instead, in plain words, or nil when the text is a number this field takes.
    func problem(in text: String, locale: Locale) -> String? {
        do {
            _ = try value(from: text, locale: locale)
            return nil
        } catch {
            return error.message
        }
    }

    // The text as the field shows it once saved, such as "28,800 vph" for "28800vph".
    func normalized(_ text: String, locale: Locale) -> String {
        guard let value = try? value(from: text, locale: locale) else { return text }
        return self.text(for: value, locale: locale)
    }

    private func problem(_ kind: NumberEntryProblem.Kind, locale: Locale) -> NumberEntryProblem {
        let example = text(for: example, locale: locale)
        switch kind {
        case .notANumber:
            return NumberEntryProblem(kind: kind, message: "Write a number, such as \(example).")
        case .unknownUnit:
            if let unit {
                return NumberEntryProblem(
                    kind: kind, message: "Write the number in \(unit), such as \(example).")
            }
            return NumberEntryProblem(
                kind: kind, message: "Write only the number, such as \(example).")
        case .belowMinimum:
            switch minimum {
            case .zero:
                return NumberEntryProblem(
                    kind: kind, message: "Write zero or more, or leave this empty.")
            case .aboveZero:
                return NumberEntryProblem(
                    kind: kind, message: "Write a number above zero, or leave this empty.")
            }
        }
    }

    private func groupingMarks(locale: Locale, decimal: Character) -> Set<Character> {
        var marks: Set<Character> = decimal == "," ? ["."] : [","]
        if let grouping = locale.groupingSeparator.flatMap(\.first), grouping != decimal,
            !grouping.isWhitespace
        {
            marks.insert(grouping)
        }
        marks.remove(decimal)
        return marks
    }

    // The number as plain ASCII digits with "." before the fraction, or nil when it is not a
    // number or its grouping is not in threes.
    private static func digits(
        _ number: String, decimal: Character, groups: Set<Character>
    ) -> String? {
        let parts = number.split(separator: decimal, maxSplits: 1, omittingEmptySubsequences: false)
        let whole = parts[0]
        let fraction = parts.count > 1 ? parts[1] : ""
        guard fraction.allSatisfy(isDigit) else { return nil }
        let wholeGroups = whole.split(omittingEmptySubsequences: false) { character in
            groups.contains(character) || character.isWhitespace
        }
        if wholeGroups.count > 1 {
            guard wholeGroups.allSatisfy({ !$0.isEmpty && $0.allSatisfy(isDigit) }),
                (1...3).contains(wholeGroups[0].count),
                wholeGroups.dropFirst().allSatisfy({ $0.count == 3 })
            else { return nil }
        } else if !whole.allSatisfy(isDigit) {
            return nil
        }
        let wholeDigits = wholeGroups.joined()
        guard !wholeDigits.isEmpty || !fraction.isEmpty else { return nil }
        let integer = wholeDigits.isEmpty ? "0" : wholeDigits
        return fraction.isEmpty ? integer : "\(integer).\(fraction)"
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    private static func withoutTrailingDot(_ unit: String) -> String {
        unit.hasSuffix(".") ? String(unit.dropLast()) : unit
    }
}

nonisolated struct NumberEntryProblem: Error, Equatable {
    enum Kind: Equatable {
        case notANumber
        case unknownUnit
        case belowMinimum
    }

    let kind: Kind
    let message: String
}
