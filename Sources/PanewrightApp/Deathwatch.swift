import Foundation
import PanewrightCore

/// Names the killer. The app has died silently on managed machines for two
/// days — no crash report, no log line, every theory (memory, EDR kills,
/// policy removal) chased by asking the user to run terminal commands. A
/// death that leaves no evidence is a death we investigate forever.
///
/// Mechanics: every health tick stamps a heartbeat (pid + time); the app's
/// own exit paths drop a clean-exit marker. At the next startup, a
/// heartbeat without a marker means the predecessor vanished mid-flight —
/// so we pull the unified log for the minutes around its last heartbeat
/// (Apple's own `log` binary, which endpoint security does not block) and
/// write anything that smells like a kill, a denial, or a removal into our
/// log. The next bug report then carries the killer's fingerprints without
/// the user lifting a finger.
enum Deathwatch {
    private static let heartbeatURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/panewright/.heartbeat")
    private static let cleanExitURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/panewright/.clean-exit")

    nonisolated static func heartbeat() {
        let stamp = "\(ProcessInfo.processInfo.processIdentifier) \(Date().timeIntervalSince1970)"
        try? stamp.write(to: heartbeatURL, atomically: true, encoding: .utf8)
        // A fresh heartbeat supersedes any stale clean-exit marker from a
        // previous life.
        try? FileManager.default.removeItem(at: cleanExitURL)
    }

    nonisolated static func markCleanExit() {
        try? Data().write(to: cleanExitURL)
    }

    static func performAutopsyIfPreviousDiedDirty() {
        defer { heartbeat() }
        guard let raw = try? String(contentsOf: heartbeatURL, encoding: .utf8) else { return }
        let parts = raw.split(separator: " ")
        guard parts.count == 2, let pid = Int32(parts[0]),
            let when = Double(parts[1]).map({ Date(timeIntervalSince1970: $0) }),
            pid != ProcessInfo.processInfo.processIdentifier,
            // Older than a day is history, not a case.
            Date().timeIntervalSince(when) < 86400,
            !FileManager.default.fileExists(atPath: cleanExitURL.path)
        else {
            try? FileManager.default.removeItem(at: cleanExitURL)
            return
        }
        DragLog.log(
            "deathwatch: previous instance (pid \(pid)) vanished without teardown"
                + " near \(when.formatted(.iso8601)) — pulling the system log")
        Task.detached(priority: .utility) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/log")
            process.arguments = [
                "show",
                "--start", formatter.string(from: when.addingTimeInterval(-90)),
                "--end", formatter.string(from: when.addingTimeInterval(150)),
                "--style", "compact",
                "--predicate",
                "eventMessage CONTAINS[c] \"panewright\" OR (process == \"kernel\" AND"
                    + " (eventMessage CONTAINS[c] \"kill\" OR eventMessage CONTAINS[c] \"deny\"))",
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let interesting = String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .filter { line in
                    let l = line.lowercased()
                    return l.contains("kill") || l.contains("deny") || l.contains("remov")
                        || l.contains("uninstall") || l.contains("exited")
                        || l.contains("quarantine") || l.contains("policy")
                }
                .suffix(12)
            if interesting.isEmpty {
                DragLog.log("deathwatch: system log shows nothing named around the death")
            } else {
                for line in interesting {
                    DragLog.log("deathwatch: \(line)")
                }
            }
        }
    }
}
