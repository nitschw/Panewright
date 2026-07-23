import Foundation

/// Append-only diagnostics for the drag pipeline: ~/Library/Logs/Panewright.log
enum DragLog {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/Panewright.log")

    static func log(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
