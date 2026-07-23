import AppKit
import PanewrightCore

/// Credential entry lives in ``CredentialsWindow`` — a real window, because
/// secure fields inside NSAlert accessory views truncate pasted tokens in
/// accessory apps.
@MainActor
enum TokenPrompt {
    static func ask(
        service: String, displayName: String, onSaved: @escaping () -> Void = {}
    ) {
        CredentialsWindow.present(
            service: service, displayName: displayName, onSaved: onSaved)
    }
}
