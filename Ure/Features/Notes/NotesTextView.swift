import AppKit
import SwiftUI

// A plain-text editor for a record's notes, and for a job's problem. The text view leaves Undo
// to the autosave field, so ⌘Z and ⇧⌘Z work the same before and after a change saves.
struct NotesTextView: NSViewRepresentable {
    let field: AutosaveField
    let text: String
    let isEditable: Bool
    var label = "Notes"
    var identifier = "recordNotes"

    func makeCoordinator() -> Coordinator { Coordinator(field: field) }

    func makeNSView(context: Context) -> NotesEditingView {
        let view = NotesEditingView.make()
        view.delegate = context.coordinator
        view.onBeginEditing = context.coordinator.beginEditing
        view.onEndEditing = context.coordinator.endEditing
        view.isEditable = isEditable
        view.setText(text)
        view.setAccessibilityLabel(label)
        view.setAccessibilityIdentifier(identifier)
        return view
    }

    func updateNSView(_ view: NotesEditingView, context: Context) {
        view.isEditable = isEditable
        if view.string != text { view.setText(text) }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView view: NotesEditingView, context: Context
    ) -> CGSize? {
        let width = min(proposal.width ?? NotesLayout.maximumWidth, NotesLayout.maximumWidth)
        return CGSize(width: width, height: view.height(fittingWidth: width))
    }

    static func dismantleNSView(_ view: NotesEditingView, coordinator: Coordinator) {
        coordinator.endEditing()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let field: AutosaveField

        init(field: AutosaveField) { self.field = field }

        func beginEditing() {
            if !field.isEditing { field.beginEditing() }
        }

        func endEditing() {
            if field.isEditing { field.endEditing() }
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            field.change(to: view.string, undoManager: view.window?.undoManager)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                field.revert(undoManager: textView.window?.undoManager)
                return true
            case #selector(NSResponder.insertTab(_:)):
                textView.window?.selectNextKeyView(nil)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
                return true
            default:
                return false
            }
        }
    }
}

final class NotesEditingView: NSTextView {
    var onBeginEditing: () -> Void = {}
    var onEndEditing: () -> Void = {}
    private var storage: NSTextStorage?

    // TextKit 1 lets the editor measure its height for SwiftUI.
    static func make() -> NotesEditingView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: NSSize(width: NotesLayout.maximumWidth, height: .greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        let view = NotesEditingView(frame: .zero, textContainer: container)
        view.storage = storage
        return view
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        isRichText = false
        importsGraphics = false
        allowsUndo = false
        drawsBackground = false
        isHorizontallyResizable = false
        isVerticallyResizable = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        font = Self.font
        textColor = .labelColor
        defaultParagraphStyle = Self.paragraphStyle
        typingAttributes = Self.attributes
    }

    required init?(coder: NSCoder) { return nil }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if isEditable { onBeginEditing() }
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        onEndEditing()
        return true
    }

    @objc func insertToday(_ sender: Any?) {
        guard isEditable else { return }
        insertText(
            Date.now.formatted(date: .long, time: .omitted), replacementRange: selectedRange())
    }

    func setText(_ text: String) {
        let location = selectedRange().location
        string = text
        let length = (text as NSString).length
        textStorage?.setAttributes(Self.attributes, range: NSRange(location: 0, length: length))
        setSelectedRange(NSRange(location: min(location, length), length: 0))
    }

    func height(fittingWidth width: CGFloat) -> CGFloat {
        guard let textContainer, let layoutManager else { return NotesLayout.lineHeight }
        textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).maxY
        let extra = layoutManager.extraLineFragmentRect.maxY
        return ceil(max(used, extra, NotesLayout.lineHeight))
    }

    private static let font = NSFont.systemFont(ofSize: NotesLayout.textSize)

    private static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = NotesLayout.lineHeight
        style.maximumLineHeight = NotesLayout.lineHeight
        return style
    }()

    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: paragraphStyle,
        .baselineOffset: (NotesLayout.lineHeight - (font.ascender - font.descender)) / 4,
    ]
}
