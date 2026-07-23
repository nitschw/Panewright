import AppKit
import PanewrightCore
import SwiftUI

struct OnboardingView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to Panewright")
                .font(.title2)
                .bold()
            Text("Truly tiled windows for macOS. A few pieces need setting up — each is one click.")
                .foregroundStyle(.secondary)
            Divider()

            SetupRow(
                done: model.aerospaceInstalled,
                working: model.installing.contains("AeroSpace"),
                title: "AeroSpace — the tiling engine",
                detail: model.aerospaceInstalled
                    ? "Installed"
                    : "Installs via Homebrew. No password needed.",
                actionLabel: "Install"
            ) {
                model.installAeroSpace()
            }

            SetupRow(
                done: model.status == .running,
                title: "AeroSpace is running with Accessibility",
                detail: aerospaceDetail,
                actionLabel: aerospaceActionLabel
            ) {
                model.launchOrRestartAeroSpace()
            }

            SetupRow(
                done: model.dragToTileActive,
                title: "Drag-to-Tile permissions",
                detail: model.dragToTileActive
                    ? "Active"
                    : "Needs Accessibility and Input Monitoring. After granting both, quit and reopen Panewright.",
                actionLabel: "Grant…"
            ) {
                model.finishDragToTileSetup()
            }

            SetupRow(
                done: model.bordersInstalled,
                working: model.installing.contains("JankyBorders"),
                title: "JankyBorders — focus borders (optional)",
                detail: model.bordersInstalled ? "Installed" : "Colored border around the focused window.",
                actionLabel: "Install"
            ) {
                model.installBorders()
            }

            SetupRow(
                done: model.sketchybarInstalled,
                working: model.installing.contains("SketchyBar"),
                title: "SketchyBar — status bar (optional)",
                detail: model.sketchybarInstalled
                    ? "Installed"
                    : "Workspace numbers, mode badge, clock.",
                actionLabel: "Install"
            ) {
                model.installSketchyBar()
            }

            if model.isBundled {
                SetupRow(
                    done: model.launchAtLogin,
                    title: "Launch at login",
                    detail: model.launchAtLogin
                        ? "Enabled"
                        : "Panewright assembles your tiling environment at startup.",
                    actionLabel: "Enable"
                ) {
                    model.setLaunchAtLogin(true)
                }
            }

            Divider()
            HStack {
                Text(model.lastMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Done") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 560)
        .task {
            while !Task.isCancelled {
                if model.setupVisible {
                    model.refreshStatus()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var aerospaceDetail: String {
        switch model.status {
        case .running: "Running"
        case .notRunning: "Installed but not running."
        case .unresponsive:
            "Grant Accessibility to AeroSpace in System Settings → Privacy & Security, then restart it."
        case .notInstalled: "Install AeroSpace first."
        }
    }

    private var aerospaceActionLabel: String? {
        switch model.status {
        case .notRunning: "Launch"
        case .unresponsive: "Restart AeroSpace"
        case .running, .notInstalled: nil
        }
    }
}

struct SetupRow: View {
    var done: Bool
    var working: Bool = false
    var title: String
    var detail: String
    var actionLabel: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if working {
                ProgressView()
                    .controlSize(.small)
            } else if !done, let actionLabel, let action {
                Button(actionLabel, action: action)
            }
        }
    }
}
