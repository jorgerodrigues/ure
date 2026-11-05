import Foundation

// The task and part editors save a blank text as no value.
nonisolated enum DraftText {
    static func optional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return trimmed
    }
}
