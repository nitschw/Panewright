import AppKit
import SwiftUI

@MainActor
final class EditorWindowController {
    private var window: NSWindow?

    func show(appModel: AppModel) {
        if window == nil {
            let model = EditorModel(appModel: appModel)
            let hosting = NSHostingController(rootView: EditorView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Panewright Editor"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
