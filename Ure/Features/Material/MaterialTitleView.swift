import AppKit
import SwiftUI

// A one-line title editor for a material tile. Like the notes editor, it leaves Undo to the
// autosave field: its cell turns off the field editor's own Undo while a title is edited.
// Return ends editing, and Esc puts back the title from when editing began.
struct MaterialTitleView: NSViewRepresentable {
    let field: AutosaveField
    let text: String
    let isEditable: Bool
    let endEditing: (AutosaveField, UndoManager?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(field: field, endEditing: endEditing) }

    func makeNSView(context: Context) -> MaterialTitleField {
        let view = MaterialTitleField()
        view.delegate = context.coordinator
        view.onBeginEditing = context.coordinator.beginEditing
        view.isEditable = isEditable
        view.stringValue = text
        return view
    }

    func updateNSView(_ view: MaterialTitleField, context: Context) {
        view.isEditable = isEditable
        if let editor = view.currentEditor() as? NSTextView {
            if editor.string != text { editor.string = text }
        } else if view.stringValue != text {
            view.stringValue = text
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView view: MaterialTitleField, context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? MaterialLayout.tileWidth, height: MaterialLayout.titleHeight)
    }

    static func dismantleNSView(_ view: MaterialTitleField, coordinator: Coordinator) {
        coordinator.finishEditing(undoManager: view.window?.undoManager)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let field: AutosaveField
        private let endEditing: (AutosaveField, UndoManager?) -> Void

        init(field: AutosaveField, endEditing: @escaping (AutosaveField, UndoManager?) -> Void) {
            self.field = field
            self.endEditing = endEditing
        }

        func beginEditing() {
            if !field.isEditing { field.beginEditing() }
        }

        func finishEditing(undoManager: UndoManager?) {
            if field.isEditing { endEditing(field, undoManager) }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextField else { return }
            field.change(to: view.stringValue, undoManager: view.window?.undoManager)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            let view = notification.object as? NSView
            finishEditing(undoManager: view?.window?.undoManager)
        }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                field.revert(undoManager: textView.window?.undoManager)
                textView.string = field.text
                control.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                control.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.insertTab(_:)):
                if !ReadingOrder.moveFocus(from: control, forward: true) {
                    control.window?.selectNextKeyView(nil)
                }
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                if !ReadingOrder.moveFocus(from: control, forward: false) {
                    control.window?.selectPreviousKeyView(nil)
                }
                return true
            default:
                return false
            }
        }
    }
}

final class MaterialTitleField: NSTextField, ReadingOrderStop {
    var onBeginEditing: () -> Void = {}

    init() {
        super.init(frame: .zero)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .default
        font = .systemFont(ofSize: MaterialLayout.titleSize)
        textColor = .labelColor
        cell?.usesSingleLineMode = true
        cell?.allowsUndo = false
        truncatesAtRest()
        // VoiceOver reads the field's cell, so the label goes on the cell as well as the field.
        setAccessibilityLabel("Material title")
        cell?.setAccessibilityLabel("Material title")
        setAccessibilityIdentifier("materialTitle")
    }

    required init?(coder: NSCoder) { return nil }

    var takesReadingOrderFocus: Bool { isEditable }

    // A long title scrolls while you type and ends in "…" at rest, as the in-place fields do.
    override func becomeFirstResponder() -> Bool {
        scrollsWhileTyping()
        guard super.becomeFirstResponder() else {
            truncatesAtRest()
            return false
        }
        if isEditable { onBeginEditing() }
        return true
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        truncatesAtRest()
    }
}

// The page values come from the "4 Watch" artboard on the Paper page "Rework · Simple".
enum MaterialLayout {
    static let tileWidth: CGFloat = 156
    static let previewHeight: CGFloat = 104
    static let titleSize: CGFloat = 13
    static let titleHeight: CGFloat = 18
    static let tileSpacing: CGFloat = 12
    static let stripHeight: CGFloat = 56
    static let cornerRadius: CGFloat = 8
    static let pageTileMinimum: CGFloat = 140
    static let pagePreviewHeight: CGFloat = 116
    static let pageRadius: CGFloat = 10
    static let pageStripHeight: CGFloat = 48
    static let detailSize: CGFloat = 11
    static let chipHeight: CGFloat = 24
    static let chipSpacing: CGFloat = 8
    static let chipTextSize: CGFloat = 12
}
