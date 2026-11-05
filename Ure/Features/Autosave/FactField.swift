import Foundation
import Observation

// What a fact field takes. The problem says what to write instead, or is nil when the field
// takes the text. The normalized text is how the field shows a saved text, such as "28,800 vph"
// for "28800vph".
nonisolated struct FactRule: Sendable {
    let problem: @Sendable (String) -> String?
    let normalized: @Sendable (String) -> String

    static let anyText = FactRule(problem: { _ in nil }, normalized: trimmed)

    static func required(_ message: String) -> FactRule {
        FactRule(
            problem: { text in trimmed(text).isEmpty ? message : nil }, normalized: trimmed)
    }

    static func number(_ entry: NumberEntry, locale: Locale) -> FactRule {
        FactRule(
            problem: { entry.problem(in: $0, locale: locale) },
            normalized: { entry.normalized($0, locale: locale) })
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// One fact on a record page, such as a caliber's beat rate, written in place. The text saves as
// you type through AutosaveField. A text the rule does not take stays on screen and never
// saves, so the record keeps its last good value. The field says so once focus leaves it, and
// keeps saying so while you correct it. As you type, a suggestion can finish the text, and
// accepting it puts the whole suggestion in the field.
@Observable
final class FactField {
    let label: String
    let prompt: String
    let editor: AutosaveField
    private(set) var suggestion: String?
    @ObservationIgnored private let rule: FactRule
    @ObservationIgnored private let suggestions: () -> [String]
    private var flagsWhileEditing = false

    init(
        label: String, prompt: String, actionName: String, text: String, rule: FactRule,
        suggestions: @escaping () -> [String] = { [] },
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

    // Why the text does not save yet, and the value the record keeps meanwhile. It shows once
    // focus has left the field, so a half-typed number is never called wrong.
    var problem: String? {
        guard editor.text != editor.savedText, let message = rule.problem(editor.text) else {
            return nil
        }
        if editor.isEditing, !flagsWhileEditing { return nil }
        let saved = editor.savedText.isEmpty ? "empty" : "“\(editor.savedText)”"
        return "\(message) The saved value stays \(saved)."
    }

    func beginEditing() {
        flagsWhileEditing = problem != nil
        suggestion = nil
        editor.beginEditing()
    }

    func change(to newText: String, undoManager: UndoManager?) {
        let isTypingOn = newText.count > editor.text.count && newText.hasPrefix(editor.text)
        editor.change(to: newText, undoManager: undoManager)
        suggestion = isTypingOn ? match(for: newText) : nil
    }

    // Puts the whole suggestion in the field. False when there is none.
    @discardableResult
    func acceptSuggestion(undoManager: UndoManager?) -> Bool {
        guard let suggestion else { return false }
        self.suggestion = nil
        editor.change(to: suggestion, undoManager: undoManager)
        return true
    }

    func dismissSuggestion() { suggestion = nil }

    // Saves at once. Once saved, the field shows the text the way it shows a saved value.
    func endEditing() {
        suggestion = nil
        flagsWhileEditing = false
        editor.endEditing()
        Task { await showSavedText() }
    }

    func revert(undoManager: UndoManager?) {
        suggestion = nil
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

    private func match(for text: String) -> String? {
        guard !text.isEmpty else { return nil }
        return suggestions().first { candidate in
            candidate.count > text.count
                && candidate.range(
                    of: text, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
