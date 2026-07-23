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

@Suite struct ConfluenceSearchTests {
    @Test func scopesBuildTheRightCQL() {
        let title = ConfluenceProvider.cql(for: "deploy runbook", scope: .title)
        #expect(title.contains("title ~ \"deploy runbook\""))
        #expect(!title.contains("text ~"))

        let content = ConfluenceProvider.cql(for: "deploy", scope: .content)
        #expect(content.contains("text ~ \"deploy\""))

        let all = ConfluenceProvider.cql(for: "deploy", scope: .all)
        #expect(all.contains("title ~ \"deploy\" or text ~ \"deploy\""))

        // Author filtering is local, so its query stays the recency feed.
        #expect(
            ConfluenceProvider.cql(for: "Ada", scope: .author)
                == "type = page order by lastmodified desc")
        #expect(
            ConfluenceProvider.cql(for: "", scope: .all)
                == "type = page order by lastmodified desc")
    }

    @Test func escapesQuotesSoQueriesCantBreakOut() {
        let cql = ConfluenceProvider.cql(for: "say \"hi\"", scope: .title)
        #expect(cql.contains("\\\"hi\\\""))
    }

    @Test func findsImageSourcesIncludingLazyAttributes() {
        // Shape taken from a real Confluence page: a thumbnail in src and
        // the full-size attachment in data-image-src.
        let html = """
            <p>text</p>
            <img class="confluence-embedded-image" loading="lazy"
              src="https://site.atlassian.net/wiki/download/thumbnails/1/a.png?version=1"
              data-image-src="https://site.atlassian.net/wiki/download/attachments/1/a.png?version=1"
              srcset="https://site.atlassian.net/wiki/download/thumbnails/1/a.png 2x">
            <img src="data:image/gif;base64,R0lGOD">
            """
        let sources = ConfluenceProvider.imageSources(in: html)
        #expect(sources.count == 2)
        #expect(sources.contains { $0.contains("download/attachments/1/a.png") })
        #expect(sources.contains { $0.contains("download/thumbnails/1/a.png?version=1") })
        // Already-inlined images need no fetching.
        #expect(!sources.contains { $0.hasPrefix("data:") })
    }

    @Test func parsesAtlassianTimestamps() {
        #expect(ConfluenceProvider.parseDate("2026-07-23T01:22:33.000Z") != nil)
        #expect(ConfluenceProvider.parseDate("2026-07-23T01:22:33Z") != nil)
        #expect(ConfluenceProvider.parseDate("nope") == nil)
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
