import AppKit
import SwiftUI

// The one-line AppKit field of a checklist line: a step, a heading, or the row that adds a step.
// Like the facts, it leaves Undo to its editor. Return starts the next step, and on a step
// without text it moves on, like Tab. Backspace on a step without text removes it. The Up and
// Down arrows move between the lines. Esc puts back the text from when the cursor came in.
struct ChecklistStepTextView: NSViewRepresentable {
    let editor: ChecklistEditor
    let id: UUID
    let text: String
    let style: InPlaceStyle
    let isTicked: Bool
    let isEditable: Bool
    let label: String
    let prompt: String
    let focus: StepCursor?

    func makeCoordinator() -> Coordinator { Coordinator(editor: editor, id: id) }

    func makeNSView(context: Context) -> ChecklistStepField {
        let view = ChecklistStepField(prompt: prompt, style: style)
        view.delegate = context.coordinator
        view.onBeginEditing = context.coordinator.beginEditing
        view.stepMenu = context.coordinator.menu
        view.setAccessibilityIdentifier("checklistStep-\(id.uuidString)")
        update(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: ChecklistStepField, context: Context) {
        update(view, coordinator: context.coordinator)
    }

    private func update(_ view: ChecklistStepField, coordinator: Coordinator) {
        // SwiftUI can reuse this view for another line, so it follows the current one.
        coordinator.editor = editor
        coordinator.id = id
        view.setStyle(style)
        view.setPrompt(prompt)
        view.setLabel(label)
        view.textColor = isTicked || style == .heading ? .secondaryLabelColor : .labelColor
        view.isEditable = isEditable
        if !isEditable, view.currentEditor() != nil { view.window?.makeFirstResponder(nil) }
        if let fieldEditor = view.currentEditor() as? NSTextView {
            if fieldEditor.string != text { fieldEditor.string = text }
        } else if view.stringValue != text {
            view.stringValue = text
        }
        guard let focus, isEditable else { return }
        if view.currentEditor() != nil {
            editor.focusTaken(id)
        } else {
            view.requestFocus(placing: focus) { [editor, id] in editor.focusTaken(id) }
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView view: ChecklistStepField, context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? InPlaceLayout.minimumWidth,
            height: view.intrinsicContentSize.height)
    }

    static func dismantleNSView(_ view: ChecklistStepField, coordinator: Coordinator) {
        coordinator.finishEditing()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var editor: ChecklistEditor
        var id: UUID

        init(editor: ChecklistEditor, id: UUID) {
            self.editor = editor
            self.id = id
        }

        func beginEditing() {
            if editor.editingID != id { editor.beginEditing(id) }
        }

        func finishEditing() {
            editor.endEditing(id)
        }

        func menu(_ view: NSView) -> NSMenu? {
            editor.menu(for: id) { [weak view] in view?.window?.undoManager }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextField else { return }
            editor.change(id, to: view.stringValue, undoManager: view.window?.undoManager)
            // A line that became a heading drops the "# " it started with.
            if let text = editor.step(id)?.text, let fieldEditor = view.currentEditor(),
                fieldEditor.string != text
            {
                fieldEditor.string = text
            }
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
                editor.revert(id, undoManager: undoManager)
                textView.string = editor.step(id)?.text ?? ""
                control.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                if !editor.startNextStep(after: id) { moveOn(from: control, forward: true) }
                return true
            case #selector(NSResponder.insertTab(_:)):
                moveOn(from: control, forward: true)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                moveOn(from: control, forward: false)
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                guard textView.string.isEmpty else { return false }
                return editor.removeEmptyStep(id)
            case #selector(NSResponder.moveUp(_:)):
                return editor.focusLine(nextTo: id, by: -1)
            case #selector(NSResponder.moveDown(_:)):
                return editor.focusLine(nextTo: id, by: 1)
            default:
                return false
            }
        }

        // Tab, Shift-Tab, and Return on a step without text, move to the next or previous field
        // in reading order.
        private func moveOn(from control: NSControl, forward: Bool) {
            guard !InPlaceTextField.moveFocus(from: control, forward: forward) else { return }
            if forward {
                control.window?.selectKeyView(following: control)
            } else {
                control.window?.selectKeyView(preceding: control)
            }
        }
    }
}

// The AppKit field of a checklist line. While the job can change, its right-click menu holds
// the line's commands, also while you type, above the usual text commands.
final class ChecklistStepField: InPlaceTextField {
    var stepMenu: (NSView) -> NSMenu? = { _ in nil }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isEditable, let steps = stepMenu(self) else { return super.menu(for: event) }
        return steps
    }

    // The field editor asks its delegate, this field, for the menu while you type.
    @objc(textView:menu:forEvent:atIndex:)
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int)
        -> NSMenu?
    {
        guard isEditable, let steps = stepMenu(self) else { return menu }
        steps.addItem(.separator())
        for item in menu.items {
            menu.removeItem(item)
            steps.addItem(item)
        }
        return steps
    }
}
