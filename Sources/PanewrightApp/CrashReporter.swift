import AppKit
import PanewrightCore
import Foundation

/// Consent-first crash reporting with zero infrastructure: on launch, detect
/// crashes from the previous session (macOS .ips reports + our own logged
/// exceptions), show the user the exact report text, and offer to open a
/// pre-filled GitHub issue. Nothing is transmitted by the app itself.
@MainActor
enum CrashReporter {
    private static let lastCheckKey = "crashReporterLastCheck"
    private static let issuesURL = "https://github.com/nitschw/Panewright/issues/new"

    /// Detection only — never presents UI. Presenting a modal at launch is
    /// how a single crash turns into a crash loop; the caller surfaces this
    /// through the menu instead.
    static func pendingReport() -> String? {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: lastCheckKey) as? Date
        defaults.set(Date(), forKey: lastCheckKey)
        // First run (fresh install or bundle-ID change): baseline only —
        // never report crashes that predate this install.
        guard let lastCheck = stored else { return nil }

        var sections: [String] = []
        if let crash = latestCrashReport(since: lastCheck) {
            sections.append(crash)
        }
        if let exceptions = loggedExceptions(since: lastCheck) {
            sections.append(exceptions)
        }
        guard !sections.isEmpty else { return nil }
        return assemble(sections)
    }

    /// User-initiated: show the report and offer to file it.
    static func present(report: String) {
        offer(report: report)
    }

    private static func assemble(_ sections: [String]) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var report = """
            **Panewright** \(version) (\(build))
            **macOS** \(ProcessInfo.processInfo.operatingSystemVersionString)


            """
        report += sections.joined(separator: "\n\n")
        report += logSection(maxCharacters: 2000)
        if report.count > 6500 {
            report = String(report.prefix(6500)) + "\n… (truncated)"
        }
        return report
    }

    /// The recent log, because "it crashed" plus the last minute of what the
    /// app was doing is a diagnosable report; "it crashed" alone is a shrug.
    private static func logSection(maxCharacters: Int) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard
            let tail = LogTail.tail(
                of: home + "/Library/Logs/Panewright.log",
                lines: 40, maxCharacters: maxCharacters)
        else { return "" }
        // The engine's log rides along: an engine that dies on every launch
        // writes its reason (and its dying words) there and nowhere else —
        // the one report that needed it most arrived without it.
        let engineTail = LogTail.tail(
            of: home + "/Library/Logs/PanewrightEngine.log",
            lines: 20, maxCharacters: 1500)
        let engineSection = engineTail.map {
            """


            <details><summary>Engine log</summary>

            ```
            \($0)
            ```
            </details>
            """
        } ?? ""
        return """


            <details><summary>Recent log</summary>

            ```
            \(tail)
            ```
            </details>
            \(engineSection)

            _Full logs: `~/Library/Logs/Panewright.log` and `PanewrightEngine.log` — drag them onto this issue if asked._
            """
    }

    /// User-initiated bug report — same delivery as a crash report, but the
    /// story is theirs to tell and the logs come along automatically.
    static func bugReport() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return """
            **Panewright** \(version) (\(build))
            **macOS** \(ProcessInfo.processInfo.operatingSystemVersionString)

            **What happened:**

            **What I expected:**
            \(logSection(maxCharacters: 3200))\(recentCrashes())
            """
    }

    /// Any crash either of our processes suffered in the last day rides
    /// along with a bug report. The app dies without ceremony on a hard
    /// crash — no log line, no exception handler — so the user's "it
    /// crashed" report used to arrive with logs that showed nothing wrong.
    /// macOS wrote the whole story to DiagnosticReports; include it.
    private static func recentCrashes() -> String {
        let since = Date().addingTimeInterval(-86400)
        var sections: [String] = []
        if let app = latestCrashReport(since: since, prefix: "panewright") {
            sections.append(app)
        }
        if let engine = latestCrashReport(since: since, prefix: "AeroSpace") {
            sections.append(engine)
        }
        guard !sections.isEmpty else { return "" }
        return "\n\n" + sections.joined(separator: "\n\n")
    }

    // MARK: macOS crash reports (.ips)

    private static func latestCrashReport(since: Date, prefix: String = "panewright") -> String? {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/DiagnosticReports")
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else {
            return nil
        }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
        }
        let latest =
            files
            .filter {
                $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "ips"
                    && modified($0) > since
            }
            .max { modified($0) < modified($1) }
        guard let latest, let raw = try? String(contentsOf: latest, encoding: .utf8) else {
            return nil
        }
        return summary(fromIPS: raw, name: latest.lastPathComponent)
    }

    private static func summary(fromIPS raw: String, name: String) -> String? {
        let parts = raw.split(separator: "\n", maxSplits: 1)
        guard parts.count == 2,
            let payload = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8))
                as? [String: Any]
        else {
            return nil
        }
        var lines = ["### Crash report `\(name)`"]
        if let termination = (payload["termination"] as? [String: Any])?["indicator"] as? String {
            lines.append("Termination: \(termination)")
        }
        if let exception = payload["exception"] as? [String: Any] {
            let type = exception["type"] as? String ?? "?"
            let signal = exception["signal"] as? String ?? ""
            lines.append("Exception: \(type) \(signal)")
        }
        let faulting = payload["faultingThread"] as? Int ?? 0
        if let threads = payload["threads"] as? [[String: Any]], faulting < threads.count,
            let frames = threads[faulting]["frames"] as? [[String: Any]],
            let images = payload["usedImages"] as? [[String: Any]] {
            lines.append("```")
            for frame in frames.prefix(15) {
                let image = (frame["imageIndex"] as? Int)
                    .flatMap { $0 < images.count ? images[$0]["name"] as? String : nil } ?? "?"
                let symbol =
                    frame["symbol"] as? String ?? "+\(frame["imageOffset"] ?? 0)"
                lines.append("\(image)  \(symbol)")
            }
            lines.append("```")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Our own logged exceptions (name + reason — the good stuff)

    private static func loggedExceptions(since: Date) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/Panewright.log")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        let matches = content.split(separator: "\n").suffix(300).filter { line in
            guard line.contains("UNCAUGHT EXCEPTION") else { return false }
            let stamp = line.split(separator: " ").first
                .flatMap { formatter.date(from: String($0)) } ?? .distantPast
            return stamp > since
        }
        guard !matches.isEmpty else { return nil }
        return "### Logged exceptions\n```\n" + matches.joined(separator: "\n") + "\n```"
    }

    // MARK: Consent + submission

    private static func offer(report: String) {
        let alert = NSAlert()
        alert.messageText = "Panewright crashed last session"
        alert.informativeText =
            "This is the full report, exactly as it would appear. Nothing is sent unless you submit the pre-filled GitHub issue yourself."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        let text = NSTextView(frame: scroll.bounds)
        text.string = report
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        text.autoresizingMask = [.width]
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Open GitHub Issue…")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var components = URLComponents(string: issuesURL)!
        components.queryItems = [
            URLQueryItem(name: "title", value: title(for: report)),
            URLQueryItem(
                name: "labels",
                value: report.contains("**What happened:**") ? "bug" : "crash"),
            URLQueryItem(name: "body", value: report),
        ]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    private static func title(for report: String) -> String {
        for line in report.split(separator: "\n") {
            if line.hasPrefix("Termination:") || line.hasPrefix("Exception:") {
                return "Crash: \(line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "report")"
            }
        }
        return "Crash report"
    }
}
