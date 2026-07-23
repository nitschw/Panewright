import AppKit
import PanewrightCore
import SwiftUI

enum ItemSort: String, CaseIterable, Identifiable {
    case updated = "Updated"
    case priority = "Priority"
    case status = "Status"
    case title = "Title"

    var id: String { rawValue }
}

/// The panel behind a bar pill: everything waiting for you, searchable,
/// sortable, one click from the browser.
struct IntegrationsPanelView: View {
    let model: IntegrationsModel
    let focusedService: String?
    @State private var query = ""
    @State private var sort: ItemSort = .updated
    @State private var statusFilter: String?

    private var visible: [IntegrationsModel.ServiceState] {
        guard let focusedService else { return model.services }
        return model.services.filter { $0.id == focusedService }
    }

    private var allItems: [IntegrationItem] {
        visible.flatMap(\.items)
    }

    private var statuses: [String] {
        Array(Set(allItems.compactMap { $0.status?.trimmingCharacters(in: .whitespaces) }))
            .filter { !$0.isEmpty }
            .sorted()
    }

    private func filtered(_ items: [IntegrationItem]) -> [IntegrationItem] {
        var result = items
        if let statusFilter {
            result = result.filter { $0.status == statusFilter }
        }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            result = result.filter {
                $0.title.lowercased().contains(needle)
                    || $0.subtitle.lowercased().contains(needle)
                    || ($0.status?.lowercased().contains(needle) ?? false)
            }
        }
        switch sort {
        case .updated:
            result.sort { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
        case .priority:
            result.sort { Self.priorityRank($0.priority) < Self.priorityRank($1.priority) }
        case .status:
            result.sort { ($0.status ?? "") < ($1.status ?? "") }
        case .title:
            result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return result
    }

    /// Highest urgency first; unknown priorities sink.
    static func priorityRank(_ priority: String?) -> Int {
        switch priority?.lowercased() {
        case let value? where value.contains("highest") || value.contains("blocker"): 0
        case let value? where value.contains("critical"): 1
        case let value? where value.contains("high") || value.contains("major"): 2
        case let value? where value.contains("medium") || value.contains("normal"): 3
        case let value? where value.contains("low") || value.contains("minor"): 4
        case let value? where value.contains("lowest") || value.contains("trivial"): 5
        default: 6
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            controls
            Divider()
            content
        }
        .frame(width: 520, height: 480)
    }

    private var header: some View {
        HStack {
            Text(visible.count == 1 ? (visible.first?.displayName ?? "") : "Work Items")
                .font(.headline)
            if let last = model.lastRefresh {
                Text(last.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06)))

            Picker("", selection: $sort) {
                ForEach(ItemSort.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 110)

            if !statuses.isEmpty {
                Menu {
                    Button("All statuses") { statusFilter = nil }
                    Divider()
                    ForEach(statuses, id: \.self) { status in
                        Button(status) { statusFilter = status }
                    }
                } label: {
                    Label(statusFilter ?? "Status", systemImage: "line.3.horizontal.decrease")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 120)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(visible) { service in
                    let items = filtered(service.items)
                    if let error = service.error {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(error)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            if error.contains("credentials") {
                                Button("Add \(service.displayName) token…") {
                                    model.promptForToken(
                                        service: service.id, displayName: service.displayName)
                                }
                            }
                        }
                        .padding(16)
                    } else if items.isEmpty {
                        Text(
                            service.isLoading
                                ? "Loading…"
                                : (service.items.isEmpty
                                    ? "Nothing waiting on you."
                                    : "No matches.")
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(16)
                    } else {
                        if visible.count > 1 {
                            Text(service.displayName.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                        }
                        ForEach(items) { item in
                            ItemRow(item: item)
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

private struct ItemRow: View {
    let item: IntegrationItem
    @State private var hovering = false

    private var statusColor: Color {
        switch StatusKind.classify(item.status ?? item.badge) {
        case .todo: .secondary
        case .inProgress: .blue
        case .review: .purple
        case .blocked: .red
        case .done: .green
        case .other: .accentColor
        }
    }

    var body: some View {
        Button {
            NSWorkspace.shared.open(item.url)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                if let badge = item.badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(statusColor.opacity(0.16)))
                        .overlay(Capsule().stroke(statusColor.opacity(0.35)))
                        .frame(minWidth: 64, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(item.subtitle)
                        if let updated = item.updated {
                            Text("·")
                            Text(updated.formatted(.relative(presentation: .numeric)))
                        }
                    }
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
