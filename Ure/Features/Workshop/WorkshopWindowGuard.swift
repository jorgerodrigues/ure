import AppKit
import SwiftUI

final class WorkshopApplicationDelegate: NSObject, NSApplicationDelegate {
    var restore: RestoreState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let restore else { return .terminateNow }
        if restore.isActivating { return .terminateCancel }
        let editing = restore.session.editing
        if editing.material.isExporting { return .terminateCancel }
        guard editing.hasUnsavedFields || !editing.queue.isIdle else {
            return finish(sender, restore: restore)
        }
        Task { await saveFieldsThenTerminate(sender, restore: restore) }
        return .terminateLater
    }

    // Every change still waiting saves first, in order, also one made while another saved. A
    // save that fails asks whether to try again, discard the changes, or stay.
    private func saveFieldsThenTerminate(_ sender: NSApplication, restore: RestoreState) async {
        guard
            await UnsavedChanges.save(
                restore.session.editing, toQuit: true,
                ask: { UnsavedChanges.askAboutFailure($0, toQuit: true) })
        else {
            sender.reply(toApplicationShouldTerminate: false)
            return
        }
        switch finish(sender, restore: restore) {
        case .terminateNow: sender.reply(toApplicationShouldTerminate: true)
        case .terminateCancel: sender.reply(toApplicationShouldTerminate: false)
        default: break
        }
    }

    // Quits at once, or first discards a restore that was staged.
    private func finish(
        _ sender: NSApplication, restore: RestoreState
    ) -> NSApplication.TerminateReply {
        if restore.staged == nil, !restore.isStaging { return .terminateNow }
        finishTermination(sender, restore: restore)
        return .terminateLater
    }

    private func finishTermination(_ sender: NSApplication, restore: RestoreState) {
        Task {
            let discarded = await restore.discardForTermination()
            sender.reply(toApplicationShouldTerminate: discarded)
        }
    }
}

struct WorkshopWindowGuard: NSViewRepresentable {
    let editing: WorkshopEditing

    func makeNSView(context: Context) -> WindowProbe {
        WindowProbe(editing: editing)
    }

    func updateNSView(_ nsView: WindowProbe, context: Context) {}

    static func dismantleNSView(_ nsView: WindowProbe, coordinator: ()) {
        nsView.restoreDelegate()
    }

    final class WindowProbe: NSView {
        private let editing: WorkshopEditing
        private var proxy: WindowDelegateProxy?
        private weak var installedWindow: NSWindow?

        init(editing: WorkshopEditing) {
            self.editing = editing
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { return nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard installedWindow !== window else { return }
            restoreDelegate()
            guard let window else { return }
            let proxy = WindowDelegateProxy(editing: editing, originalDelegate: window.delegate)
            self.proxy = proxy
            installedWindow = window
            window.delegate = proxy
        }

        func restoreDelegate() {
            if let window = installedWindow, window.delegate === proxy {
                window.delegate = proxy?.originalDelegate
            }
            proxy = nil
            installedWindow = nil
        }
    }

    nonisolated final class WindowDelegateProxy: NSObject, NSWindowDelegate {
        private let editing: WorkshopEditing
        let originalDelegate: (any NSWindowDelegate)?
        @MainActor private var isSavingToClose = false

        init(editing: WorkshopEditing, originalDelegate: (any NSWindowDelegate)?) {
            self.editing = editing
            self.originalDelegate = originalDelegate
        }

        // Closing waits for the typing on screen and every change still waiting, then closes.
        @MainActor
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard editing.hasUnsavedFields || !editing.queue.isIdle else {
                return originalDelegate?.windowShouldClose?(sender) ?? true
            }
            guard !isSavingToClose else { return false }
            isSavingToClose = true
            Task { @MainActor [weak sender] in
                let saved = await UnsavedChanges.save(
                    editing, toQuit: false,
                    ask: { UnsavedChanges.askAboutFailure($0, toQuit: false) })
                isSavingToClose = false
                guard saved, let sender, originalDelegate?.windowShouldClose?(sender) ?? true
                else { return }
                sender.close()
            }
            return false
        }

        override func responds(to selector: Selector) -> Bool {
            super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector) -> Any? {
            originalDelegate
        }
    }
}

// Before quitting or closing the window, every change saves. A save that fails asks whether to
// try again, discard the changes that did not save, or stay. Text that a field does not take,
// such as a blank name, asks whether to quit without it.
@MainActor
enum UnsavedChanges {
    // What to do about a save that failed.
    enum Choice {
        case tryAgain
        case discard
        case stay
    }

    // True when the app can quit or the window can close.
    static func save(
        _ editing: WorkshopEditing, toQuit: Bool, ask: @MainActor (String) -> Choice,
        confirmTextNotValid: @MainActor () -> Bool = { confirmQuitWithTextNotValid() }
    ) async -> Bool {
        while true {
            switch await editing.saveAllFields() {
            case .saved:
                return true
            case .textNotValid:
                return !toQuit || confirmTextNotValid()
            case .stopped:
                switch ask(editing.failure ?? "") {
                case .tryAgain: editing.tryAgain()
                case .discard: editing.discardUnsaved()
                case .stay: return false
                }
            }
        }
    }

    static func askAboutFailure(_ failure: String, toQuit: Bool) -> Choice {
        let alert = NSAlert()
        alert.messageText = "Some changes did not save."
        let leaving = toQuit ? "quit" : "close the window"
        alert.informativeText =
            "\(failure) Try again to save them, or discard them to \(leaving) without them."
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Discard Changes").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .tryAgain
        case .alertSecondButtonReturn: return .discard
        default: return .stay
        }
    }

    static func confirmQuitWithTextNotValid() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Some of your typing did not save."
        alert.informativeText =
            "The text is still on screen. If you quit now, the text that did not save is lost."
        alert.addButton(withTitle: "Stay")
        alert.addButton(withTitle: "Quit Anyway").hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}
