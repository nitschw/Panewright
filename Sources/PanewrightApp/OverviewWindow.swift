import AppKit
import PanewrightCore
import SwiftUI

/// The workspace overview (`$mod+o`) — the Mission Control that virtual
/// workspaces otherwise take away. Mission Control shows every window of
/// every workspace in one undifferentiated pile because hidden workspaces
/// park their windows rather than living on real Spaces; this shows the
/// truth instead: one card per occupied workspace, its windows named with
/// their app icons, click to go.
///
/// Wireframes and icons, not screenshots — thumbnails would need the Screen
/// Recording permission, and a permission prompt is a steep price for
/// pictures when names and icons already answer "where is my thing".
@MainActor
final class OverviewController {
    static let shared = OverviewController()
    private var panel: NSPanel?

    func toggle() {
        if let panel, panel.isVisible {
            close()
            return
        }
        open()
    }

    private func open() {
        let workspaces = Self.snapshot()
        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                styleMask: [.nonactivatingPanel, .fullSizeContentView, .titled],
                backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            self.panel = panel
        }
        panel.contentView = NSHostingView(
            rootView: OverviewView(
                workspaces: workspaces,
                dismiss: { [weak self] in self?.close() }))
        if let screen = Monitors.focusedScreen() {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(x: frame.midX - 380, y: frame.midY - 240))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    struct WorkspaceCard: Identifiable {
        let id: String
        let focused: Bool
        let windows: [(id: UInt32, title: String, icon: NSImage?)]
    }

    private static func snapshot() -> [WorkspaceCard] {
        guard let cli = AeroSpaceCLI.locate(),
            let output = try? cli.run([
                "list-windows", "--all", "--format",
                "%{workspace}|%{window-id}|%{app-pid}|%{app-name}|%{window-title}",
            ])
        else { return [] }
        let focused =
            (try? cli.run(["list-workspaces", "--focused"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var grouped: [String: [(UInt32, String, NSImage?)]] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 4)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 4, let id = UInt32(parts[1]) else { continue }
            // The scratchpad ("S") and pill ("P") parking workspaces aren't
            // places anyone goes on purpose.
            guard parts[0].count == 1, parts[0].first?.isNumber == true else { continue }
            let icon = Int32(parts[2]).flatMap {
                NSRunningApplication(processIdentifier: $0)?.icon
            }
            let title = parts.count == 5 && !parts[4].isEmpty ? parts[4] : parts[3]
            grouped[parts[0], default: []].append((id, title, icon))
        }
        return grouped.keys.sorted().map { key in
            WorkspaceCard(
                id: key, focused: key == focused,
                windows: grouped[key]!.map { (id: $0.0, title: $0.1, icon: $0.2) })
        }
    }
}

struct OverviewView: View {
    let workspaces: [OverviewController.WorkspaceCard]
    let dismiss: () -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14
            ) {
                ForEach(workspaces) { card in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(card.id)
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(card.focused ? Color.accentColor : .primary)
                            if card.focused {
                                Text("current").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        ForEach(card.windows, id: \.id) { window in
                            HStack(spacing: 8) {
                                if let icon = window.icon {
                                    Image(nsImage: icon).resizable()
                                        .frame(width: 18, height: 18)
                                }
                                Text(window.title).font(.callout).lineLimit(1)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                _ = try? AeroSpaceCLI.locate()?
                                    .run(["focus", "--window-id", "\(window.id)"])
                                dismiss()
                            }
                        }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        _ = try? AeroSpaceCLI.locate()?.run(["workspace", card.id])
                        dismiss()
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 760, height: 480)
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }
}
