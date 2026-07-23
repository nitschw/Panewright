import AppKit
import PanewrightCore
import SwiftUI

/// Your issues in context: epics and parent stories above, subtasks below,
/// with your own work highlighted so you can see where it fits.
struct JiraHierarchyView: View {
    let nodes: [JiraIssueNode]
    let isLoading: Bool
    let error: String?

    var body: some View {
        Group {
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else if isLoading && nodes.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if nodes.isEmpty {
                Text("Nothing to map.")
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                List(nodes, children: \.optionalChildren) { node in
                    NodeRow(node: node)
                }
                .listStyle(.sidebar)
            }
        }
    }
}

private struct NodeRow: View {
    let node: JiraIssueNode

    private var statusColor: Color {
        switch StatusKind.classify(node.status) {
        case .todo: .secondary
        case .inProgress: .blue
        case .review: .purple
        case .blocked: .red
        case .done: .green
        case .other: .accentColor
        }
    }

    private var typeIcon: String {
        switch node.type.lowercased() {
        case let value where value.contains("epic"): "bolt.fill"
        case let value where value.contains("bug"): "ladybug.fill"
        case let value where value.contains("sub"): "arrow.turn.down.right"
        case let value where value.contains("story"): "book.fill"
        default: "square.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: typeIcon)
                .font(.caption)
                .foregroundStyle(node.isMine ? Color.accentColor : .secondary)
                .frame(width: 14)
            Text(node.key)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(node.summary)
                .lineLimit(1)
                .fontWeight(node.isMine ? .semibold : .regular)
            if node.isMine {
                Text("you")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.22)))
            }
            Spacer(minLength: 6)
            if !node.status.isEmpty {
                Text(node.status)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(statusColor.opacity(0.16)))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            NSWorkspace.shared.open(node.url)
        }
        .help("Double-click to open \(node.key)")
    }
}

extension JiraIssueNode {
    /// SwiftUI's outline list wants nil, not an empty array, for leaves.
    var optionalChildren: [JiraIssueNode]? {
        children.isEmpty ? nil : children
    }
}
