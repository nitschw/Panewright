import AppKit
import SwiftUI

/// Hosts the setup checklist in a plain NSWindow — version-safe for a
/// MenuBarExtra-only app that occasionally needs a real window.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    var onVisibilityChange: ((Bool) -> Void)?

    func show(model: AppModel) {
        if window == nil {
            let hosting = NSHostingController(rootView: OnboardingView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Panewright Setup"
            // Keep .resizable: SwiftUI content with a flexible dimension in a
            // fixed-size window produces unsatisfiable constraints, and
            // AppKit turns that into a fatal exception mid display cycle.
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onVisibilityChange?(true)
    }

    func windowWillClose(_ notification: Notification) {
        onVisibilityChange?(false)
    }
}
