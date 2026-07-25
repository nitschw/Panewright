import AppKit
import SwiftUI

@MainActor
final class EditorWindowController {
    private var window: NSWindow?
    private var model: EditorModel?

    func show(appModel: AppModel, reveal: EditorModel.Target? = nil) {
        let model = self.model ?? EditorModel(appModel: appModel)
        if self.model == nil {
            let hosting = NSHostingController(rootView: EditorView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Panewright Editor"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            self.window = window
            self.model = model
        } else {
            // Anything else that writes the config (the conflicts window,
            // a profile switch) would otherwise be clobbered by this model's
            // next save. Edits here are debounce-saved within 350ms, so
            // there's nothing unsaved to lose.
            model.reloadFromDisk(quiet: true)
        }
        // After the reload — row ids are regenerated on every load.
        if let reveal { model.reveal(reveal) }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
