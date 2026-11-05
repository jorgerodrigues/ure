import AppKit
import SwiftUI

// What a step's right-click menu and the Checklist menu offer, with the same names and keys.
enum StepCommand: CaseIterable {
    case tick
    case heading
    case moveUp
    case moveDown
    case delete

    var key: KeyEquivalent? {
        switch self {
        case .tick: "u"
        case .moveUp: .upArrow
        case .moveDown: .downArrow
        case .heading, .delete: nil
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .tick: [.command, .shift]
        case .moveUp, .moveDown: [.command, .control]
        case .heading, .delete: []
        }
    }

    // The same key for an AppKit menu item.
    var keyEquivalent: String {
        switch self {
        case .tick: "U"
        case .moveUp: Self.functionKey(NSUpArrowFunctionKey)
        case .moveDown: Self.functionKey(NSDownArrowFunctionKey)
        case .heading, .delete: ""
        }
    }

    private static func functionKey(_ key: Int) -> String {
        UnicodeScalar(UInt16(key)).map { String(Character($0)) } ?? ""
    }

    // The command's name for a step, such as "Tick Step" or "Untick Step".
    func title(for step: ChecklistStep?) -> String {
        switch self {
        case .tick: step?.isTicked == true ? "Untick Step" : "Tick Step"
        case .heading: step?.isHeading == true ? "Make Step" : "Make Heading"
        case .moveUp: "Move Step Up"
        case .moveDown: "Move Step Down"
        case .delete: step?.isHeading == true ? "Delete Heading" : "Delete Step"
        }
    }

    var keyModifiers: NSEvent.ModifierFlags {
        switch self {
        case .tick: [.command, .shift]
        case .moveUp, .moveDown: [.command, .control]
        case .heading, .delete: []
        }
    }
}

extension ChecklistEditor {
    func title(of command: StepCommand, for id: UUID) -> String {
        command.title(for: step(id))
    }

    func canPerform(_ command: StepCommand, for id: UUID) -> Bool {
        switch command {
        case .tick: canTick(id)
        case .heading: canChange(id)
        case .moveUp: canMove(id, by: -1)
        case .moveDown: canMove(id, by: 1)
        case .delete: step(id) != nil
        }
    }

    func perform(_ command: StepCommand, for id: UUID, undoManager: UndoManager?) {
        guard canPerform(command, for: id) else { return }
        switch command {
        case .tick: toggleTick(id, undoManager: undoManager)
        case .heading: toggleHeading(id, undoManager: undoManager)
        case .moveUp: move(id, by: -1, undoManager: undoManager)
        case .moveDown: move(id, by: 1, undoManager: undoManager)
        case .delete: delete(id, undoManager: undoManager)
        }
    }

    // The step's right-click menu in AppKit, for the step's text.
    func menu(for id: UUID, undoManager: @escaping () -> UndoManager?) -> NSMenu? {
        guard step(id) != nil else { return nil }
        let menu = NSMenu(title: "Step")
        menu.autoenablesItems = false
        for command in StepCommand.allCases {
            if command == .delete { menu.addItem(.separator()) }
            let action = StepMenuAction { [weak self] in
                self?.perform(command, for: id, undoManager: undoManager())
            }
            let item = NSMenuItem(
                title: title(of: command, for: id), action: #selector(StepMenuAction.choose),
                keyEquivalent: command.keyEquivalent)
            // The item keeps its action, which is its target.
            item.representedObject = action
            item.target = action
            item.keyEquivalentModifierMask = command.keyModifiers
            item.isEnabled = canPerform(command, for: id)
            menu.addItem(item)
        }
        return menu
    }
}

// What a step's menu item does when you choose it.
final class StepMenuAction: NSObject {
    private let run: () -> Void

    init(run: @escaping () -> Void) { self.run = run }

    @objc func choose() { run() }
}
