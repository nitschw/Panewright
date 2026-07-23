import AppKit
import PanewrightCore
import SwiftUI

/// The panel behind a bar pill: everything waiting for you, one click from
/// the browser.
struct IntegrationsPanelView: View {
    let model: IntegrationsModel
    let focusedService: String?

    private var visible: [IntegrationsModel.ServiceState] {
        guard let focusedService else { return model.services }
        return model.services.filter { $0.id == focusedService }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(visible.first?.displayName ?? "Integrations")
                    .font(.headline)
                Spacer()
                if let last = model.lastRefresh {
                    Text(last.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { service in
                        if let error = service.error {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(error)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                if error.contains("credentials") {
                                    Button("Add \(service.displayName) token…") {
                                        model.promptForToken(
                                            service: service.id,
                                            displayName: service.displayName)
                                    }
                                }
                            }
                            .padding(16)
                        } else if service.items.isEmpty {
                            Text(service.isLoading ? "Loading…" : "Nothing waiting on you.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(16)
                        } else {
                            ForEach(service.items) { item in
                                ItemRow(item: item)
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 460, height: 420)
    }
}

private struct ItemRow: View {
    let item: IntegrationItem
    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(item.url)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                if let badge = item.badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(
                                badge == "review"
                                    ? Color.accentColor.opacity(0.25)
                                    : Color.secondary.opacity(0.18)))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.06) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

@MainActor
final class IntegrationsWindowController {
    private var window: NSWindow?

    func show(model: IntegrationsModel, service: String?) {
        let view = IntegrationsPanelView(model: model, focusedService: service)
        window?.orderOut(nil)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Panewright"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        model.refresh()
    }
}
