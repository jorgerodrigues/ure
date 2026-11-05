import Foundation
import Observation

// What a fact field takes. The problem says what to enter instead, or is nil when the field
// takes the text. The normalized text is how the field shows a saved text, such as "28,800 vph"
// for "28800vph". The unit is the end of a shown value that reads quieter, such as " vph".
nonisolated struct FactRule: Sendable {
    let problem: @Sendable (String) -> String?
    let normalized: @Sendable (String) -> String
    var unit: String? = nil

    static let anyText = FactRule(problem: { _ in nil }, normalized: trimmed)

    static func required(_ message: String) -> FactRule {
        FactRule(
            problem: { text in trimmed(text).isEmpty ? message : nil }, normalized: trimmed)
    }

    static func number(_ entry: NumberEntry, locale: Locale) -> FactRule {
        FactRule(
            problem: { entry.problem(in: $0, locale: locale) },
            normalized: { entry.normalized($0, locale: locale) }, unit: entry.shownUnit)
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// A value the library already holds that a field offers as you type, such as a maker, with a
// count such as "2 calibers".
nonisolated struct FactSuggestion: Equatable, Sendable {
    let text: String
    var detail: String? = nil
}

// One fact on a record page, such as a caliber's beat rate, written in place. The text saves as
// you type through AutosaveField. A text the rule does not take stays on screen and never
// saves, so the record keeps its last good value. The field says so once focus leaves it, and
// keeps saying so while you correct it. As you type, the library's matching values show under
// the field, and taking one puts it all in the field.
@Observable
final class FactField {
    static let maximumMatches = 5

    let label: String
    let prompt: String
    let editor: AutosaveField
    // Matches hold only for the text they were made for, so Undo or any other change of the
    // text drops them.
    private var offer: Offer?
    @ObservationIgnored private let rule: FactRule
    @ObservationIgnored private let suggestions: () -> [FactSuggestion]
    private var flagsWhileEditing = false

    init(
        label: String, prompt: String, actionName: String, text: String, rule: FactRule,
        suggestions: @escaping () -> [FactSuggestion] = { [] },
        save: @escaping (String) async throws -> Void,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.label = label
        self.prompt = prompt
        self.rule = rule
        self.suggestions = suggestions
        editor = AutosaveField(
            text: text, actionName: actionName, save: save, pause: pause,
            accepts: { rule.problem($0) == nil })
    }

    var text: String { editor.text }
    var isEditing: Bool { editor.isEditing }
    var saveError: String? { editor.saveError }
    var hasUnsavedChanges: Bool { editor.hasUnsavedChanges }
    var unit: String? { rule.unit }

    // The library's values that start with what you typed. Tab or Return takes the first.
    var matches: [FactSuggestion] {
        guard let offer, offer.typed == editor.text, editor.isEditing else { return [] }
        return offer.matches
    }

    var suggestion: String? { matches.first?.text }

    // What to enter instead. It shows once focus has left the field, so a half-typed number
    // is never called wrong.
    var problem: String? {
        guard editor.text != editor.savedText, let message = rule.problem(editor.text) else {
            return nil
        }
        if editor.isEditing, !flagsWhileEditing { return nil }
        return message
    }

    func beginEditing() {
        flagsWhileEditing = problem != nil
        offer = nil
        editor.beginEditing()
    }

    func change(to newText: String, undoManager: UndoManager?) {
        let isTypingOn = newText.count > editor.text.count && newText.hasPrefix(editor.text)
        editor.change(to: newText, undoManager: undoManager)
        let found = isTypingOn ? matches(for: newText) : []
        offer = found.isEmpty ? nil : Offer(typed: newText, matches: found)
    }

    // Puts a match in the field, the first one unless another is given. False when there is
    // none.
    @discardableResult
    func acceptSuggestion(_ chosen: FactSuggestion? = nil, undoManager: UndoManager?) -> Bool {
        guard let taken = chosen ?? matches.first, matches.contains(taken) else { return false }
        offer = nil
        editor.change(to: taken.text, undoManager: undoManager)
        return true
    }

    func dismissSuggestion() { offer = nil }

    // A choice from a pop-up, such as a winding: one Undo step, saved at once.
    func choose(_ text: String, undoManager: UndoManager?) {
        beginEditing()
        change(to: text, undoManager: undoManager)
        endEditing()
    }

    // Saves at once. Once saved, the field shows the text the way it shows a saved value.
    func endEditing() {
        offer = nil
        flagsWhileEditing = false
        editor.endEditing()
        Task { await showSavedText() }
    }

    func revert(undoManager: UndoManager?) {
        offer = nil
        editor.revert(undoManager: undoManager)
    }

    // Adopts a stored value when nothing typed here is waiting to save.
    func refresh(_ stored: String) { editor.refresh(stored) }

    func saveNow() { editor.saveNow() }

    @discardableResult
    func flush() async -> Bool { await editor.flush() }

    func discardUndo() { editor.discardUndo() }

    private func showSavedText() async {
        guard await editor.flush(), !editor.isEditing else { return }
        editor.refresh(rule.normalized(editor.text))
    }

    private func matches(for text: String) -> [FactSuggestion] {
        guard !text.isEmpty else { return [] }
        let found = suggestions().filter { candidate in
            candidate.text.count > text.count
                && candidate.text.range(
                    of: text, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
        }
        return Array(found.prefix(Self.maximumMatches))
    }
}

private struct Offer {
    let typed: String
    let matches: [FactSuggestion]
}
