import AppKit
import SwiftUI

// The one-line AppKit field under an in-place fact. Like the notes editor, it leaves Undo to
// the autosave field. Tab and Shift-Tab move to the next and previous field in reading order.
// Return takes a suggestion and moves on too. Esc puts back the text from when editing began.
// A suggestion shows in grey after the typed text, and Tab, Return or the Right Arrow at the
// end takes it. At rest, a value's unit reads quieter than its number.
struct InPlaceTextView: NSViewRepresentable {
    let field: FactField
    let text: String
    let suggestion: String?
    let style: InPlaceStyle
    let isEditable: Bool
    let identifier: String
    let requestsFocus: Bool
    let didFocus: () -> Void
    // A value that reads quieter, such as a fitted part's name.
    var isQuiet = false

    func makeCoordinator() -> Coordinator { Coordinator(field: field) }

    func makeNSView(context: Context) -> InPlaceTextField {
        let view = InPlaceTextField(prompt: field.prompt, style: style)
        view.delegate = context.coordinator
        view.onBeginEditing = context.coordinator.beginEditing
        view.isEditable = isEditable
        view.show(text, unit: field.unit)
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
        let color: NSColor = isQuiet ? .secondaryLabelColor : .labelColor
        if view.textColor != color { view.textColor = color }
        // A field that stops taking changes while you type in it ends the edit, which saves it.
        if !isEditable, view.currentEditor() != nil { view.window?.makeFirstResponder(nil) }
        if let editor = view.currentEditor() as? NSTextView {
            if editor.string != text { editor.string = text }
        } else {
            view.show(text, unit: field.unit)
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

class InPlaceTextField: NSTextField {
    var onBeginEditing: () -> Void = {}
    private let suggestionView = SuggestionTextView()
    private var textFont: NSFont
    private var focusRequest: (() -> Void)?
    private var focusCursor: StepCursor?

    init(prompt: String, style: InPlaceStyle) {
        textFont = style.font
        super.init(frame: .zero)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        font = textFont
        textColor = .labelColor
        lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        cell?.allowsUndo = false
        setPrompt(prompt)
        suggestionView.font = textFont
        suggestionView.isHidden = true
        addSubview(suggestionView)
    }

    required init?(coder: NSCoder) { return nil }

    // A checklist line changes its font when it becomes a heading, and keeps the cursor.
    func setStyle(_ style: InPlaceStyle) {
        guard textFont != style.font else { return }
        let prompt = placeholderAttributedString?.string ?? ""
        textFont = style.font
        font = textFont
        suggestionView.font = textFont
        placeholderAttributedString = NSAttributedString(
            string: prompt, attributes: [.font: textFont, .foregroundColor: NSColor.clear])
    }

    // Shows a value at rest, with its unit in the secondary colour, such as "19,800" and " vph".
    func show(_ text: String, unit: String?) {
        guard let unit, text.hasSuffix(unit), text.count > unit.count else {
            if stringValue != text { stringValue = text }
            return
        }
        let shown = NSMutableAttributedString(
            string: text, attributes: [.font: textFont, .foregroundColor: NSColor.labelColor])
        let length = (text as NSString).length
        let unitLength = (unit as NSString).length
        shown.addAttribute(
            .foregroundColor, value: NSColor.secondaryLabelColor,
            range: NSRange(location: length - unitLength, length: unitLength))
        if attributedStringValue != shown { attributedStringValue = shown }
    }

    // VoiceOver reads the field's cell, so the label goes on the cell as well as the field.
    func setLabel(_ label: String) {
        guard accessibilityLabel() != label else { return }
        setAccessibilityLabel(label)
        cell?.setAccessibilityLabel(label)
    }

    // The prompt stays the field's placeholder for VoiceOver. InPlaceField draws it.
    func setPrompt(_ prompt: String) {
        guard placeholderAttributedString?.string != prompt else { return }
        placeholderAttributedString = NSAttributedString(
            string: prompt, attributes: [.font: textFont, .foregroundColor: NSColor.clear])
    }

    // While you type, the whole value is in the label colour.
    override func becomeFirstResponder() -> Bool {
        if isEditable { stringValue = stringValue }
        guard super.becomeFirstResponder() else { return false }
        if isEditable { onBeginEditing() }
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        performFocusRequest()
    }

    // Puts the cursor here once the field is in a window: with the text selected, or at the
    // start or the end of the text.
    func requestFocus(placing cursor: StepCursor? = nil, then didFocus: @escaping () -> Void) {
        guard focusRequest == nil, currentEditor() == nil else { return }
        focusRequest = didFocus
        focusCursor = cursor
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
            NSAttributedString(string: remainder, attributes: [.font: textFont]).size().width)
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
        let cursor = focusCursor
        focusRequest = nil
        focusCursor = nil
        Task { @MainActor [weak self] in
            guard let self, let window = self.window, window.makeFirstResponder(self),
                let editor = self.currentEditor()
            else { return }
            let length = (editor.string as NSString).length
            switch cursor {
            case .start: editor.selectedRange = NSRange(location: 0, length: 0)
            case .end: editor.selectedRange = NSRange(location: length, length: 0)
            case nil: editor.selectAll(nil)
            }
            didFocus()
        }
    }
}

// The grey rest of a suggestion. It never takes clicks, so they reach the field under it.
final class SuggestionTextView: NSView {
    var font = InPlaceStyle.body.font
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

// The body style is a 15 pt fact. The title style is the 26 pt bold name in a page header.
// A checklist heading is a 12 pt semibold line.
enum InPlaceStyle {
    case body
    case title
    case heading

    var font: NSFont {
        switch self {
        case .body: .systemFont(ofSize: InPlaceLayout.textSize)
        case .title: .systemFont(ofSize: InPlaceLayout.titleSize, weight: .bold)
        case .heading: .systemFont(ofSize: ChecklistLayout.headingSize, weight: .semibold)
        }
    }

    var boxHeight: CGFloat {
        switch self {
        case .body: InPlaceLayout.boxHeight
        case .title: InPlaceLayout.titleBoxHeight
        case .heading: ChecklistLayout.headingLineHeight
        }
    }
}

// Values from the "7 Typing" artboard on the Paper page "Rework · Simple".
enum InPlaceLayout {
    static let textSize: CGFloat = 15
    static let titleSize: CGFloat = 26
    static let boxHeight: CGFloat = 32
    static let titleBoxHeight: CGFloat = 40
    static let inset: CGFloat = 8
    static let cornerRadius: CGFloat = 8
    static let minimumWidth: CGFloat = 120
    static let ringSpread: CGFloat = 4
    static let ringOpacity: Double = 0.18
    static let labelSize: CGFloat = 11
    static let labelSpacing: CGFloat = 4
    static let messageSize: CGFloat = 12
    static let messageTop: CGFloat = 8
    static let hintSize: CGFloat = 11
    static let hintTop: CGFloat = 6
    static let listGap: CGFloat = 4
    static let listPadding: CGFloat = 5
    static let listRadius: CGFloat = 10
    static let rowHeight: CGFloat = 28
    static let rowRadius: CGFloat = 6
    static let rowTextSize: CGFloat = 13
    static let rowDetailSize: CGFloat = 12
    static let openSpacing: CGFloat = 8
    static let openWidth: CGFloat = 16
}
