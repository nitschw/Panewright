import AppKit
import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            if let url = Bundle.main.url(forResource: "logo", withExtension: "png"),
                let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 170, height: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
            }
            Text("Panewright")
                .font(.title)
                .bold()
            Text("Truly tiled windows for macOS")
                .foregroundStyle(.secondary)
            Text("Version \(version)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Text("© 2026 William Nitsch — MIT License")
                .font(.caption)
            HStack(spacing: 16) {
                Link("panewright.com", destination: URL(string: "https://panewright.com")!)
                Link(
                    "GitHub",
                    destination: URL(string: "https://github.com/nitschw/Panewright")!)
            }
            .font(.caption)
        }
        .padding(28)
        .frame(width: 340, height: 420)
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}

@MainActor
final class AboutWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: AboutView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "About Panewright"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
