import Foundation

/// One to-do: a short title (what the bar shows) and freeform notes.
public struct TodoItem: Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var title: String
    public var notes: String

    public init(title: String, notes: String = "") {
        self.title = title
        self.notes = notes
    }
}

/// Tab-separated storage at `~/.config/panewright/todo.txt`: one task per
/// line, `title<TAB>notes`, newlines in notes escaped. Plain text on purpose
/// — the list outlives every process, and the bar's shell plugin can read
/// titles with a plain `cut`.
public enum TodoStore {
    public static func defaultURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appending(path: ".config/panewright/todo.txt")
    }

    public static func load(from url: URL) -> [TodoItem] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
            line in
            let parts = line.components(separatedBy: "\t")
            let title = parts[0].trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            let notes = parts.count > 1 ? unescape(parts[1]) : ""
            return TodoItem(title: title, notes: notes)
        }
    }

    public static func save(_ items: [TodoItem], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text =
            items
            .filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { item in
                let title = item.title.replacingOccurrences(of: "\t", with: " ")
                return item.notes.isEmpty ? title : "\(title)\t\(escape(item.notes))"
            }
            .joined(separator: "\n")
        try (text.isEmpty ? "" : text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func escape(_ notes: String) -> String {
        notes
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: " ")
    }

    static func unescape(_ notes: String) -> String {
        var result = ""
        var iterator = notes.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            switch iterator.next() {
            case "n": result.append("\n")
            case "\\": result.append("\\")
            case let other?: result.append(other)
            case nil: result.append("\\")
            }
        }
        return result
    }
}
