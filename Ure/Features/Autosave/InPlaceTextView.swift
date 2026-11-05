import AppKit
import SwiftUI

// The one-line AppKit field under an in-place fact. Like the notes editor, it leaves Undo to
// the autosave field. Tab and Shift-Tab move to the next and previous field in reading order.
// Return takes a suggestion and moves on too. Esc puts back the text from when editing began.
// A suggestion shows in grey after the typed text, and Tab, Return or the Right Arrow at the
// end takes it.
struct InPlaceTextView: NSViewRepresentable {
    let field: FactField
    let text: String
    let suggestion: String?
    let isEditable: Bool
    let identifier: String
    let requestsFocus: Bool
    let didFocus: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(field: field) }

    func makeNSView(context: Context) -> InPlaceTextField {
        let view = InPlaceTextField(prompt: field.prompt)
        view.delegate = context.coordinator
        view.onBeginEditing = context.coordinator.beginEditing
        view.isEditable = isEditable
        view.stringValue = text
        view.setLabel(field.label)
        view.setAccessibilityIdentifier(identifier)
        return view
    }

    func updateNSView(_ view: InPlaceTextField, context: Context) {
        // SwiftUI can reuse this view for another record's fact, so it follows the current one.
        context.coordinator.field = field
        view.setPrompt(field.prompt)
        view.setLabel(field.label)
        view.isEditable = isEditable
        if let editor = view.currentEditor() as? NSTextView {
            if editor.string != text { editor.string = text }
        } else if view.stringValue != text {
            view.stringValue = text
        }
        view.showSuggestion(remainder)
        if requestsFocus, isEditable { view.requestFocus(then: didFocus) }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView view: InPlaceTextField, context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? InPlaceLayout.minimumWidth,
            height: view.intrinsicContentSize.height)
    }

    static func dismantleNSView(_ view: InPlaceTextField, coordinator: Coordinator) {
        coordinator.finishEditing()
    }

    // The part of the suggestion after what is typed.
    private var remainder: String? {
        guard let suggestion, field.isEditing, suggestion.count > text.count else { return nil }
        return String(suggestion.dropFirst(text.count))
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var field: FactField

        init(field: FactField) { self.field = field }

        func beginEditing() {
            if !field.isEditing { field.beginEditing() }
        }

        func finishEditing() {
            if field.isEditing { field.endEditing() }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextField else { return }
            field.change(to: view.stringValue, undoManager: view.window?.undoManager)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            finishEditing()
        }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
        ) -> Bool {
            let undoManager = textView.window?.undoManager
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                field.revert(undoManager: undoManager)
                textView.string = field.text
                control.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                take(in: textView, undoManager: undoManager)
                if !InPlaceTextField.moveFocus(from: control, forward: true) {
                    control.window?.makeFirstResponder(nil)
                }
                return true
            case #selector(NSResponder.insertTab(_:)):
                take(in: textView, undoManager: undoManager)
                if !InPlaceTextField.moveFocus(from: control, forward: true) {
                    control.window?.selectNextKeyView(nil)
                }
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                field.dismissSuggestion()
                if !InPlaceTextField.moveFocus(from: control, forward: false) {
                    control.window?.selectPreviousKeyView(nil)
                }
                return true
            case #selector(NSResponder.moveRight(_:)):
                let end = (textView.string as NSString).length
                guard textView.selectedRange() == NSRange(location: end, length: 0) else {
                    return false
                }
                return take(in: textView, undoManager: undoManager)
            default:
                return false
            }
        }

        @discardableResult
        private func take(in textView: NSTextView, undoManager: UndoManager?) -> Bool {
            guard field.acceptSuggestion(undoManager: undoManager) else { return false }
            textView.string = field.text
            return true
        }
    }
}

final class InPlaceTextField: NSTextField {
    var onBeginEditing: () -> Void = {}
    private let suggestionView = SuggestionTextView()
    private var focusRequest: (() -> Void)?

    init(prompt: String) {
        super.init(frame: .zero)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        font = Self.textFont
        textColor = .labelColor
        lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        cell?.allowsUndo = false
        setPrompt(prompt)
        suggestionView.font = Self.textFont
        suggestionView.isHidden = true
        addSubview(suggestionView)
    }

    required init?(coder: NSCoder) { return nil }

    static let textFont = NSFont.systemFont(ofSize: InPlaceLayout.textSize)

    // VoiceOver reads the field's cell, so the label goes on the cell as well as the field.
    func setLabel(_ label: String) {
        guard accessibilityLabel() != label else { return }
        setAccessibilityLabel(label)
        cell?.setAccessibilityLabel(label)
    }

    func setPrompt(_ prompt: String) {
        guard placeholderAttributedString?.string != prompt else { return }
        placeholderAttributedString = NSAttributedString(
            string: prompt,
            attributes: [.font: Self.textFont, .foregroundColor: NSColor.tertiaryLabelColor])
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if isEditable { onBeginEditing() }
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        performFocusRequest()
    }

    // Puts the cursor here with the text selected once the field is in a window.
    func requestFocus(then didFocus: @escaping () -> Void) {
        guard focusRequest == nil, currentEditor() == nil else { return }
        focusRequest = didFocus
        performFocusRequest()
    }

    // Draws the rest of a suggestion in grey right after the typed text, inside the field.
    func showSuggestion(_ remainder: String?) {
        guard let remainder, !remainder.isEmpty, let editor = currentEditor() as? NSTextView,
            let layout = editor.layoutManager, let container = editor.textContainer
        else {
            suggestionView.isHidden = true
            return
        }
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(for: container)
        guard glyphs.length > 0 else {
            suggestionView.isHidden = true
            return
        }
        let last = NSRange(location: NSMaxRange(glyphs) - 1, length: 1)
        let line = layout.lineFragmentRect(forGlyphAt: last.location, effectiveRange: nil)
        let end = layout.boundingRect(forGlyphRange: last, in: container).maxX
        let width = ceil(
            NSAttributedString(string: remainder, attributes: [.font: Self.textFont]).size().width)
        let origin = editor.textContainerOrigin
        var frame = convert(
            NSRect(x: origin.x + end, y: origin.y + line.minY, width: width, height: line.height),
            from: editor)
        frame.size.width = min(frame.width, bounds.maxX - frame.minX)
        guard frame.width > 0 else {
            suggestionView.isHidden = true
            return
        }
        suggestionView.text = remainder
        suggestionView.frame = frame
        suggestionView.isHidden = false
        addSubview(suggestionView, positioned: .above, relativeTo: nil)
    }

    // Moves focus to the next or previous in-place field in reading order: top to bottom, then
    // left to right. False when there is none in that direction.
    static func moveFocus(from control: NSControl, forward: Bool) -> Bool {
        guard let window = control.window, let content = window.contentView else { return false }
        let fields = editableFields(in: content).sorted(by: isInReadingOrder)
        guard let index = fields.firstIndex(where: { $0 === control }) else { return false }
        let target = forward ? index + 1 : index - 1
        guard fields.indices.contains(target) else { return false }
        return window.makeFirstResponder(fields[target])
    }

    private static func editableFields(in view: NSView) -> [InPlaceTextField] {
        var found: [InPlaceTextField] = []
        if let field = view as? InPlaceTextField, field.isEditable,
            !field.isHiddenOrHasHiddenAncestor
        {
            found.append(field)
        }
        for child in view.subviews { found += editableFields(in: child) }
        return found
    }

    private static func isInReadingOrder(_ lhs: InPlaceTextField, _ rhs: InPlaceTextField) -> Bool {
        let left = lhs.convert(lhs.bounds, to: nil)
        let right = rhs.convert(rhs.bounds, to: nil)
        if abs(left.maxY - right.maxY) > 1 { return left.maxY > right.maxY }
        return left.minX < right.minX
    }

    private func performFocusRequest() {
        guard let didFocus = focusRequest, window != nil else { return }
        focusRequest = nil
        Task { @MainActor [weak self] in
            guard let self, let window = self.window, window.makeFirstResponder(self) else {
                return
            }
            self.currentEditor()?.selectAll(nil)
            didFocus()
        }
    }
}

// The grey rest of a suggestion. It never takes clicks, so they reach the field under it.
final class SuggestionTextView: NSView {
    var font = InPlaceTextField.textFont
    var text = "" {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { return nil }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        ).draw(at: .zero)
    }
}

enum InPlaceLayout {
    static let textSize: CGFloat = 15
    static let lineHeight: CGFloat = 24
    static let inset: CGFloat = 6
    static let cornerRadius: CGFloat = 6
    static let minimumWidth: CGFloat = 120
    static let focusWidth: CGFloat = 3
    static let messageSize: CGFloat = 12
    static let hintSize: CGFloat = 11
    static let messageSpacing: CGFloat = 4
    static let labelWidth: CGFloat = 120
    static let columnSpacing: CGFloat = 12
}
