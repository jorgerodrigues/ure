import AppKit
import SwiftUI

final class WorkshopApplicationDelegate: NSObject, NSApplicationDelegate {
    var restore: RestoreState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let restore else { return .terminateNow }
        if restore.isActivating { return .terminateCancel }
        let editing = restore.session.editing
        if editing.isSaving { return .terminateCancel }
        guard editing.hasUnsavedFields else { return finish(sender, restore: restore) }
        Task { await saveFieldsThenTerminate(sender, restore: restore) }
        return .terminateLater
    }

    private func saveFieldsThenTerminate(_ sender: NSApplication, restore: RestoreState) async {
        guard await restore.session.editing.saveAllFields() || confirmQuitWithUnsavedFields()
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

    private func confirmQuitWithUnsavedFields() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Some of your typing did not save."
        alert.informativeText =
            "The text is still on screen. If you quit now, the text that did not save is lost."
        alert.addButton(withTitle: "Stay")
        alert.addButton(withTitle: "Quit Anyway").hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
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

        init(editing: WorkshopEditing, originalDelegate: (any NSWindowDelegate)?) {
            self.editing = editing
            self.originalDelegate = originalDelegate
        }

        @MainActor
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if editing.isSaving { return false }
            editing.saveFieldsNow()
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }

        override func responds(to selector: Selector) -> Bool {
            super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector) -> Any? {
            originalDelegate
        }
    }
}
