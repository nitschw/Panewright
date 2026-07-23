import AppKit
import PanewrightCore

/// Secure prompt for an API token. Storage is the login Keychain — tokens
/// never reach panewright.toml, which gets copied into profiles and shared.
@MainActor
enum TokenPrompt {
    @discardableResult
    static func ask(service: String, displayName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(displayName) API token"
        alert.informativeText = "Stored in your login Keychain, never in the config file."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if Keychain.hasToken(for: service) {
            alert.addButton(withTitle: "Remove")
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return false }
            return Keychain.setToken(token, for: service)
        case .alertThirdButtonReturn:
            return Keychain.setToken(nil, for: service)
        default:
            return false
        }
    }
}
