import AppKit
import PanewrightCore
import SwiftUI

@main
struct PanewrightApp: App {
    var body: some Scene {
        MenuBarExtra("Panewright", systemImage: "rectangle.split.3x1") {
            MenuContent()
        }
    }
}

struct MenuContent: View {
    var body: some View {
        Text("Panewright (dev build)")
            .font(.headline)
        Text(aeroSpaceStatus)
        Divider()
        Button("Quit Panewright") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var aeroSpaceStatus: String {
        if AeroSpaceCLI.locate() != nil {
            "AeroSpace: installed"
        } else {
            "AeroSpace: not found"
        }
    }
}
