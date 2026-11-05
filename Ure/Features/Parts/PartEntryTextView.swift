import AppKit
import SwiftUI

// The one-line AppKit field where you type a job's next part. Return adds the part, or puts the
// highlighted spare on the job, and the field is empty again with the cursor still in it, so
// the next part can follow at once. Return on an empty field moves on, like Tab. The Down and
// Up arrows move through the spares in hand. Esc empties the field, and a second Esc leaves it.
// Tab and Shift-Tab move in reading order.
struct PartEntryTextView: NSViewRepresentable {
    let entry: PartEntry
    let text: String
    let isEditable: Bool
    let identifier: String
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(entry: entry, submit: submit) }

    func makeNSView(context: Context) -> InPlaceTextField {
        let view = InPlaceTextField(prompt: PartEntryWording.prompt, style: .body)
        view.delegate = context.coordinator
        view.onBeginEditing = context.coordinator.beginEditing
        view.isEditable = isEditable
        view.stringValue = text
        view.setLabel(PartEntryWording.prompt)
        view.setAccessibilityIdentifier(identifier)
        return view
    }

    func updateNSView(_ view: InPlaceTextField, context: Context) {
        context.coordinator.entry = entry
        context.coordinator.submit = submit
        view.isEditable = isEditable
        if !isEditable, view.currentEditor() != nil { view.window?.makeFirstResponder(nil) }
        if let editor = view.currentEditor() as? NSTextView {
            if editor.string != text { editor.string = text }
        } else if view.stringValue != text {
            view.stringValue = text
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView view: InPlaceTextField, context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? InPlaceLayout.minimumWidth,
            height: view.intrinsicContentSize.height)
    }

    static func dismantleNSView(_ view: InPlaceTextField, coordinator: Coordinator) {
        coordinator.entry.endEditing()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var entry: PartEntry
        var submit: () -> Void

        init(entry: PartEntry, submit: @escaping () -> Void) {
            self.entry = entry
            self.submit = submit
        }

        func beginEditing() { entry.beginEditing() }

        func controlTextDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextField else { return }
            entry.change(to: view.stringValue)
        }

        func controlTextDidEndEditing(_ notification: Notification) { entry.endEditing() }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // Return on an empty line moves on, like Tab, so the checklist can follow.
                if entry.isBlank {
                    if !InPlaceTextField.moveFocus(from: control, forward: true) {
                        control.window?.makeFirstResponder(nil)
                    }
                } else {
                    // The line empties at once, also before SwiftUI draws it again.
                    submit()
                    textView.string = entry.text
                }
                return true
            case #selector(NSResponder.moveDown(_:)):
                guard !entry.spares.isEmpty else { return false }
                entry.moveHighlight(down: true)
                return true
            case #selector(NSResponder.moveUp(_:)):
                guard entry.highlightedID != nil else { return false }
                entry.moveHighlight(down: false)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if entry.text.isEmpty {
                    control.window?.makeFirstResponder(nil)
                } else {
                    entry.clear()
                    textView.string = ""
                }
                return true
            case #selector(NSResponder.insertTab(_:)):
                if !InPlaceTextField.moveFocus(from: control, forward: true) {
                    control.window?.selectNextKeyView(nil)
                }
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                if !InPlaceTextField.moveFocus(from: control, forward: false) {
                    control.window?.selectPreviousKeyView(nil)
                }
                return true
            default:
                return false
            }
        }
    }
}

enum PartEntryWording {
    static let prompt = "Add a part"
}
