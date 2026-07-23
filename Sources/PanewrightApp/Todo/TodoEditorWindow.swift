import AppKit
import PanewrightCore
import SwiftUI

/// Two-field task editor: title (what the bar shows) plus freeform notes.
/// Reached from the bar's popup via the panewright:// URL scheme, or from
/// the menu.
struct TodoEditorView: View {
    @State var title: String
    @State var notes: String
    let isNew: Bool
    let onSave: (String, String) -> Void
    let onResolve: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Task" : "Task")
                .font(.headline)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.body)
            Text("Notes")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $notes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor)))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor)))
            HStack {
                if !isNew {
                    Button(role: .destructive) {
                        onResolve()
                    } label: {
                        Label("Resolve", systemImage: "checkmark.circle")
                    }
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    onSave(title, notes)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420, height: 320)
    }
}

@MainActor
final class TodoEditorWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let storeURL = TodoStore.defaultURL()

    /// `index` is nil for a new task, otherwise the 0-based item to edit.
    func show(index: Int?, onCommit: @escaping () -> Void) {
        var items = TodoStore.load(from: storeURL)
        let editing = index.flatMap { $0 < items.count ? items[$0] : nil }
        if index != nil && editing == nil { return }

        let view = TodoEditorView(
            title: editing?.title ?? "",
            notes: editing?.notes ?? "",
            isNew: editing == nil,
            onSave: { [weak self] title, notes in
                let trimmed = title.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                if let index, index < items.count {
                    items[index] = TodoItem(title: trimmed, notes: notes)
                } else {
                    items.append(TodoItem(title: trimmed, notes: notes))
                }
                try? TodoStore.save(items, to: self?.storeURL ?? TodoStore.defaultURL())
                self?.close()
                onCommit()
            },
            onResolve: { [weak self] in
                if let index, index < items.count {
                    items.remove(at: index)
                    try? TodoStore.save(items, to: self?.storeURL ?? TodoStore.defaultURL())
                }
                self?.close()
                onCommit()
            },
            onCancel: { [weak self] in self?.close() })

        close()
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Panewright To-Do"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}
