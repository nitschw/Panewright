import AppKit
import Foundation
import PanewrightCore
import SwiftUI

/// Polls the enabled services, caches their items for the panel, and keeps
/// the bar's counts fresh.
@MainActor @Observable
final class IntegrationsModel {
    struct ServiceState: Identifiable {
        var id: String
        var displayName: String
        var items: [IntegrationItem] = []
        var error: String?
        var isLoading = false
    }

    private(set) var services: [ServiceState] = []
    private(set) var lastRefresh: Date?
    private var timer: Timer?
    private var config = IntegrationsConfig()
    private let statusFile = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/panewright/integrations.status")

    /// Refresh cadence: often enough to be useful, rare enough to stay well
    /// inside every service's rate limit.
    private static let interval: TimeInterval = 300

    func configure(_ config: IntegrationsConfig) {
        guard config != self.config else { return }
        self.config = config
        services = providers().map {
            ServiceState(id: $0.id, displayName: $0.displayName)
        }
        timer?.invalidate()
        timer = nil
        guard config.anyEnabled else {
            writeStatus()
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        self.timer = timer
        refresh()
    }

    private func providers() -> [any IntegrationProvider] {
        var result: [any IntegrationProvider] = []
        if config.github.enabled {
            result.append(GitHubProvider(host: config.github.host))
        }
        if config.gitlab.enabled {
            result.append(GitLabProvider(host: config.gitlab.host))
        }
        if config.jira.enabled {
            result.append(JiraProvider(host: config.jira.host, email: config.jira.user))
        }
        // Bitbucket and Confluence conform to the same protocol and plug in
        // here when their providers land.
        return result
    }

    func promptForToken(service: String, displayName: String) {
        if TokenPrompt.ask(service: service, displayName: displayName) {
            refresh()
        }
    }

    func refresh() {
        let providers = providers()
        guard !providers.isEmpty else { return }
        for index in services.indices {
            services[index].isLoading = true
        }
        Task { @MainActor in
            for provider in providers {
                do {
                    let items = try await provider.fetch()
                    update(provider.id) {
                        $0.items = items
                        $0.error = nil
                        $0.isLoading = false
                    }
                } catch {
                    update(provider.id) {
                        $0.items = []
                        $0.error = "\(error)"
                        $0.isLoading = false
                    }
                }
            }
            lastRefresh = Date()
            writeStatus()
        }
    }

    private func update(_ id: String, _ mutate: (inout ServiceState) -> Void) {
        guard let index = services.firstIndex(where: { $0.id == id }) else { return }
        mutate(&services[index])
    }

    /// The bar plugin is shell, so hand it a trivially parseable file:
    /// `id<TAB>count<TAB>label` per service.
    private func writeStatus() {
        let providersByID = Dictionary(
            uniqueKeysWithValues: providers().map { ($0.id, $0) })
        let lines = services.compactMap { service -> String? in
            guard let provider = providersByID[service.id] else { return nil }
            return "\(service.id)\t\(service.items.count)\t\(provider.barLabel)"
        }
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
            .write(to: statusFile, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [
            "-c", "/opt/homebrew/bin/sketchybar --trigger panewright_integrations 2>/dev/null",
        ]
        try? process.run()
    }
}
