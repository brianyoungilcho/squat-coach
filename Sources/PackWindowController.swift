import AppKit
import SwiftUI

@MainActor
final class PackWindowController: NSObject, NSWindowDelegate {
    var onVisibilityChange: (() -> Void)?

    private let store: PackStore
    private var window: NSWindow?

    init(store: PackStore = .shared) {
        self.store = store
    }

    var isVisible: Bool { window?.isVisible == true }

    func present(invite: String? = nil) {
        if let window {
            if let invite {
                window.contentViewController = hostingController(invite: invite)
            }
            activate(window)
            return
        }

        let window = NSWindow(contentViewController: hostingController(invite: invite))
        window.title = "Squat Coach Pack"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 640))
        window.minSize = NSSize(width: 620, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        activate(window)
        onVisibilityChange?()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        onVisibilityChange?()
    }

    private func hostingController(invite: String?) -> NSViewController {
        NSHostingController(rootView: PackView(store: store, initialInvite: invite))
    }

    private func activate(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
