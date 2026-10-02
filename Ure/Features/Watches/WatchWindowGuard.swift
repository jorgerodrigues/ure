import AppKit
import SwiftUI

final class WatchApplicationDelegate: NSObject, NSApplicationDelegate {
    var watches: WatchState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let watches else { return .terminateNow }
        if watches.isSaving || watches.isNavigationPending { return .terminateCancel }
        guard watches.hasUnsavedChanges else { return .terminateNow }
        watches.requestNavigation(
            { sender.reply(toApplicationShouldTerminate: true) },
            onCancel: { sender.reply(toApplicationShouldTerminate: false) })
        return .terminateLater
    }
}

struct WatchWindowGuard: NSViewRepresentable {
    let watches: WatchState

    func makeNSView(context: Context) -> WindowProbe {
        WindowProbe(watches: watches)
    }

    func updateNSView(_ nsView: WindowProbe, context: Context) {}

    static func dismantleNSView(_ nsView: WindowProbe, coordinator: ()) {
        nsView.restoreDelegate()
    }

    final class WindowProbe: NSView {
        private let watches: WatchState
        private var proxy: WindowDelegateProxy?
        private weak var installedWindow: NSWindow?

        init(watches: WatchState) {
            self.watches = watches
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { return nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard installedWindow !== window else { return }
            restoreDelegate()
            guard let window else { return }
            let proxy = WindowDelegateProxy(watches: watches, originalDelegate: window.delegate)
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
        private let watches: WatchState
        let originalDelegate: (any NSWindowDelegate)?

        init(watches: WatchState, originalDelegate: (any NSWindowDelegate)?) {
            self.watches = watches
            self.originalDelegate = originalDelegate
        }

        @MainActor
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if watches.isSaving { return false }
            if !watches.hasUnsavedChanges {
                return originalDelegate?.windowShouldClose?(sender) ?? true
            }
            watches.requestNavigation { [weak sender] in sender?.performClose(nil) }
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
