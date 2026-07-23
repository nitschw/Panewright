import AppKit
import PanewrightCore
import SwiftUI

/// Credential entry as a real window, not an NSAlert accessory view:
/// secure fields inside alerts drop pasted input in accessory (LSUIElement)
/// apps, which silently truncated long API tokens.
struct CredentialsView: View {
    let displayName: String
    let service: String
    let helpText: String
    @State private var token = ""
    @State private var reveal = false
    @State private var existing: Bool
    let onFinish: (Bool) -> Void

    init(
        displayName: String, service: String, helpText: String,
        onFinish: @escaping (Bool) -> Void
    ) {
        self.displayName = displayName
        self.service = service
        self.helpText = helpText
        self.onFinish = onFinish
        _existing = State(initialValue: Keychain.hasToken(for: service))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(displayName) API token")
                .font(.headline)
            Text(helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if reveal {
                    TextField("Paste your token", text: $token)
                } else {
                    SecureField("Paste your token", text: $token)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))

            HStack {
                Toggle("Show token", isOn: $reveal)
                    .toggleStyle(.checkbox)
                Spacer()
                Text("\(token.count) characters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if existing {
                Label("A token is already saved for \(displayName).", systemImage: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if existing {
                    Button(role: .destructive) {
                        Keychain.setToken(nil, for: service)
                        onFinish(true)
                    } label: {
                        Text("Remove")
                    }
                }
                Spacer()
                Button("Cancel") { onFinish(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    Keychain.setToken(trimmed, for: service)
                    onFinish(true)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460, height: 260)
    }
}

@MainActor
enum CredentialsWindow {
    private static var window: NSWindow?

    static func present(
        service: String, displayName: String, onSaved: @escaping () -> Void = {}
    ) {
        let help =
            switch service {
            case "github":
                "A personal access token with repo scope. Leave unset to use your gh CLI login."
            case "gitlab":
                "A personal access token with api (or read_api) scope."
            case "jira", "confluence":
                "An Atlassian API token from id.atlassian.com. Pair it with your account email in the editor."
            default:
                "A personal access token for \(displayName)."
            }
        let view = CredentialsView(
            displayName: displayName, service: service, helpText: help
        ) { saved in
            window?.orderOut(nil)
            window = nil
            if saved { onSaved() }
        }
        window?.orderOut(nil)
        let hosted = NSWindow(contentViewController: NSHostingController(rootView: view))
        hosted.title = "Panewright"
        hosted.styleMask = [.titled, .closable, .resizable]
        hosted.isReleasedWhenClosed = false
        hosted.center()
        hosted.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = hosted
    }
}
