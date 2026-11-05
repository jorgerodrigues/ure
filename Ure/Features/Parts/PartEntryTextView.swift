import AppKit
import SwiftUI

// One of the two AppKit fields on a job's add line: the next part's name, or its description
// after Tab, as on the parts card of the "7 Typing" artboard. Return in either adds the part, or
// puts the highlighted spare on the job, and the line is empty again with the cursor in the name,
// so the next part can follow at once. Return on an empty name moves on, like Tab. In the name,
// the Down and Up arrows move through the spares in hand. Esc empties the line, and a second Esc
// leaves it.
struct PartEntryTextView: NSViewRepresentable {
    enum Role {
        case name
        case description
    }

    let entry: PartEntry
    let role: Role
    let isEditable: Bool
    let identifier: String
    let submit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(entry: entry, role: role, submit: submit)
    }

    func makeNSView(context: Context) -> InPlaceTextField {
        let view = InPlaceTextField(prompt: prompt, style: .body)
        view.delegate = context.coordinator
        view.onBeginEditing = context.coordinator.beginEditing
        view.isEditable = isEditable
        view.stringValue = text
        view.setLabel(prompt)
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
        coordinator.finishEditing()
    }

    private var text: String {
        switch role {
        case .name: entry.text
        case .description: entry.description
        }
    }

    private var prompt: String {
        switch role {
        case .name: PartEntryWording.prompt
        case .description: PartEntryWording.descriptionPrompt
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var entry: PartEntry
        let role: Role
        var submit: () -> Void

        init(entry: PartEntry, role: Role, submit: @escaping () -> Void) {
            self.entry = entry
            self.role = role
            self.submit = submit
        }

        func beginEditing() {
            switch role {
            case .name: entry.beginEditing()
            case .description: entry.beginDescription()
            }
        }

        func finishEditing() {
            switch role {
            case .name: entry.endEditing()
            case .description: entry.endDescription()
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextField else { return }
            switch role {
            case .name: entry.change(to: view.stringValue)
            case .description: entry.changeDescription(to: view.stringValue)
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) { finishEditing() }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if entry.isBlank {
                    // Return on an empty line moves on, like Tab, so the checklist can follow.
                    if !InPlaceTextField.moveFocus(from: control, forward: true) {
                        control.window?.makeFirstResponder(nil)
                    }
                } else {
                    submit()
                    // The line empties at once, also before SwiftUI draws it again, and the
                    // cursor goes back to the name for the next part.
                    textView.string = ""
                    if role == .description {
                        _ = InPlaceTextField.moveFocus(from: control, forward: false)
                    }
                }
                return true
            case #selector(NSResponder.moveDown(_:)):
                guard role == .name, !entry.spares.isEmpty else { return false }
                entry.moveHighlight(down: true)
                return true
            case #selector(NSResponder.moveUp(_:)):
                guard role == .name, entry.highlightedID != nil else { return false }
                entry.moveHighlight(down: false)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if entry.text.isEmpty, entry.description.isEmpty {
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
    static let prompt = "Add a part or use a spare"
    static let descriptionPrompt = "Description"
}
