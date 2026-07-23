import Foundation
import Testing

@testable import PanewrightCore

@Suite struct IntegrationsConfigTests {
    @Test func parsesPerServiceSettings() throws {
        let config = try ConfigParser.parse(
            toml: """
                [integrations.github]
                enabled = true

                [integrations.gitlab]
                enabled = true
                host = "gitlab.example.com"

                [integrations.jira]
                enabled = true
                host = "company.atlassian.net"
                user = "me@example.com"
                """)
        #expect(config.integrations.github.enabled)
        #expect(config.integrations.gitlab.host == "gitlab.example.com")
        #expect(config.integrations.jira.user == "me@example.com")
        #expect(config.integrations.bitbucket.enabled == false)
        #expect(config.integrations.enabledIDs == ["github", "gitlab", "jira"])
        #expect(config.integrations.anyEnabled)
    }

    @Test func integrationsRoundTripThroughSerializer() throws {
        var config = PanewrightConfig.default
        config.integrations.gitlab = .init(enabled: true, host: "gitlab.example.com")
        config.integrations.jira = .init(
            enabled: true, host: "company.atlassian.net", user: "me@example.com")
        let toml = PanewrightConfigSerializer.emit(config)
        #expect(try ConfigParser.parse(toml: toml) == config)
        // Secrets must never be serialized — they live in the Keychain.
        #expect(!toml.lowercased().contains("token"))
    }

    @Test func defaultsToNoIntegrations() {
        #expect(PanewrightConfig.default.integrations.anyEnabled == false)
        #expect(PanewrightConfig.default.integrations.enabledIDs.isEmpty)
    }
}

@Suite struct GitHubProviderTests {
    @Test func derivesRepositoryAndNumberFromURL() {
        #expect(
            GitHubProvider.repository(from: "https://github.com/nitschw/Panewright/pull/12")
                == "nitschw/Panewright #12")
    }
}

@Suite struct GitLabProviderTests {
    @Test func mapsPipelineStatusesToBubbles() {
        #expect(GitLabProvider.pipelineDot["success"] == "🟢")
        #expect(GitLabProvider.pipelineDot["failed"] == "🔴")
        #expect(GitLabProvider.pipelineDot["running"] == "🔵")
    }
}

@Suite struct JiraProviderTests {
    @Test func usesTheAssignedUnresolvedQuery() {
        #expect(JiraProvider.defaultJQL.contains("assignee = currentUser()"))
        #expect(JiraProvider.defaultJQL.contains("resolution = Unresolved"))
    }

    @Test func parsesJiraTimestamps() {
        #expect(JiraProvider.parseDate("2026-07-23T01:22:33.000-0700") != nil)
        #expect(JiraProvider.parseDate("2026-07-23T01:22:33-0700") != nil)
        #expect(JiraProvider.parseDate("not a date") == nil)
    }
}

@Suite struct ConfluenceFavoritesTests {
    @Test func favoritesRoundTripThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pw-favs-\(UUID().uuidString).tsv")
        defer { try? FileManager.default.removeItem(at: url) }
        let pages = [
            ConfluencePage(
                id: "123", title: "Runbook: deploys", space: "Platform",
                url: URL(string: "https://example.atlassian.net/wiki/x/123")!),
            ConfluencePage(
                id: "456", title: "Onboarding", space: "People",
                url: URL(string: "https://example.atlassian.net/wiki/x/456")!),
        ]
        try ConfluenceFavorites.save(pages, to: url)
        #expect(ConfluenceFavorites.load(from: url) == pages)
    }

    @Test func emptyFavoritesFileLoadsEmpty() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pw-favs-\(UUID().uuidString).tsv")
        defer { try? FileManager.default.removeItem(at: url) }
        try ConfluenceFavorites.save([], to: url)
        #expect(ConfluenceFavorites.load(from: url).isEmpty)
    }
}

@Suite struct StatusClassificationTests {
    @Test func bucketsWorkflowStatesAcrossServices() {
        #expect(StatusKind.classify("In Progress") == .inProgress)
        #expect(StatusKind.classify("In Development") == .inProgress)
        #expect(StatusKind.classify("Code Review") == .review)
        #expect(StatusKind.classify("review") == .review)
        #expect(StatusKind.classify("Blocked") == .blocked)
        #expect(StatusKind.classify("Done") == .done)
        #expect(StatusKind.classify("Resolved") == .done)
        #expect(StatusKind.classify("To Do") == .todo)
        #expect(StatusKind.classify("Backlog") == .todo)
        #expect(StatusKind.classify(nil) == .other)
    }
}
