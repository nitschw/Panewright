import AppKit
import Foundation

/// Consent-first crash reporting with zero infrastructure: on launch, detect
/// crashes from the previous session (macOS .ips reports + our own logged
/// exceptions), show the user the exact report text, and offer to open a
/// pre-filled GitHub issue. Nothing is transmitted by the app itself.
@MainActor
enum CrashReporter {
    private static let lastCheckKey = "crashReporterLastCheck"
    private static let issuesURL = "https://github.com/nitschw/Panewright/issues/new"

    static func checkAndOffer() {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: lastCheckKey) as? Date
        defaults.set(Date(), forKey: lastCheckKey)
        // First run (fresh install or bundle-ID change): baseline only —
        // never report crashes that predate this install.
        guard let lastCheck = stored else { return }

        var sections: [String] = []
        if let crash = latestCrashReport(since: lastCheck) {
            sections.append(crash)
        }
        if let exceptions = loggedExceptions(since: lastCheck) {
            sections.append(exceptions)
        }
        guard !sections.isEmpty else { return }
        offer(report: assemble(sections))
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
        if report.count > 5500 {
            report = String(report.prefix(5500)) + "\n… (truncated)"
        }
        return report
    }

    // MARK: macOS crash reports (.ips)

    private static func latestCrashReport(since: Date) -> String? {
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
                $0.lastPathComponent.hasPrefix("panewright") && $0.pathExtension == "ips"
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
            URLQueryItem(name: "labels", value: "crash"),
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
