import AppKit
import SwiftUI

final class WorkshopApplicationDelegate: NSObject, NSApplicationDelegate {
    var restore: RestoreState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let restore else { return .terminateNow }
        if restore.isActivating { return .terminateCancel }
        let editing = restore.session.editing
        if editing.isSaving || editing.isNavigationPending { return .terminateCancel }
        if !editing.hasUnsavedChanges {
            if restore.staged == nil, !restore.isStaging { return .terminateNow }
            finishTermination(sender, restore: restore)
            return .terminateLater
        }
        editing.requestNavigation(
            { self.finishTermination(sender, restore: restore) },
            onCancel: { sender.reply(toApplicationShouldTerminate: false) })
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
            if !editing.hasUnsavedChanges {
                return originalDelegate?.windowShouldClose?(sender) ?? true
            }
            editing.requestNavigation { [weak sender] in sender?.performClose(nil) }
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
