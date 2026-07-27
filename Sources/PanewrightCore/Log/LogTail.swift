import Foundation

/// The last lines of a log file, bounded twice over — for embedding in a
/// pre-filled GitHub issue, where the whole report has to survive being a
/// URL (GitHub truncates bodies around 8KB of query string). The log itself
/// rotates at 1MB; what travels is the tail that usually holds the story.
public enum LogTail {
    public static func tail(
        of path: String, lines maxLines: Int = 60, maxCharacters: Int = 3500
    ) -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8),
            !content.isEmpty
        else { return nil }
        var lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        if lines.count > maxLines { lines = lines.suffix(maxLines) }
        var text = lines.joined(separator: "\n")
        if text.count > maxCharacters {
            text = "…" + String(text.suffix(maxCharacters))
        }
        return text
    }

    /// Rename to `.1` (replacing any previous `.1`) once the file outgrows
    /// the limit, so logs occupy at most twice the cap and the previous
    /// generation survives one rotation for post-mortems.
    public static func rotate(_ path: String, limit: Int = 1_000_000) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size]
                as? Int, size > limit
        else { return }
        let previous = path + ".1"
        try? FileManager.default.removeItem(atPath: previous)
        try? FileManager.default.moveItem(atPath: path, toPath: previous)
    }
}
