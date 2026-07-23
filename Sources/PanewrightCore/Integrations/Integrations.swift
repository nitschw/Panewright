import Foundation

/// One actionable thing from an external service: a pull request awaiting
/// your review, an assigned ticket, a page you were mentioned on.
public struct IntegrationItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var badge: String?
    public var url: URL

    public init(id: String, title: String, subtitle: String, badge: String? = nil, url: URL) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.url = url
    }
}

/// A service Panewright can poll. Adding GitLab, Bitbucket, Jira, or
/// Confluence means conforming here — the bar, the panel, the refresher,
/// and credential storage are all provider-agnostic.
public protocol IntegrationProvider: Sendable {
    /// Stable slug used in config, the Keychain, and panewright:// URLs.
    var id: String { get }
    var displayName: String { get }
    /// Short bar label, e.g. "PR".
    var barLabel: String { get }
    func fetch() async throws -> [IntegrationItem]
}

public enum IntegrationError: Error, CustomStringConvertible {
    case missingCredentials(String)
    case http(Int, String)
    case malformedResponse

    public var description: String {
        switch self {
        case .missingCredentials(let service):
            "No credentials for \(service) — add a token in Panewright's settings"
        case .http(let code, let detail):
            "\(service(for: code)) (HTTP \(code))\(detail.isEmpty ? "" : ": \(detail)")"
        case .malformedResponse:
            "Unexpected response from the service"
        }
    }

    private func service(for code: Int) -> String {
        switch code {
        case 401, 403: "Not authorized"
        case 404: "Not found"
        case 429: "Rate limited"
        default: "Request failed"
        }
    }
}

/// Per-service settings. Secrets never live here — see ``Keychain``.
public struct IntegrationsConfig: Equatable, Sendable {
    public struct Service: Equatable, Sendable {
        public var enabled: Bool
        /// Host for self-hosted or per-tenant services — `gitlab.example.com`,
        /// `company.atlassian.net`. Empty means the public cloud service.
        public var host: String
        /// Account identifier where the API needs one alongside the token
        /// (Jira Cloud uses email + API token as basic auth). Not a secret.
        public var user: String

        public init(enabled: Bool = false, host: String = "", user: String = "") {
            self.enabled = enabled
            self.host = host
            self.user = user
        }
    }

    public var github: Service
    public var gitlab: Service
    public var bitbucket: Service
    public var jira: Service
    public var confluence: Service

    public init(
        github: Service = Service(),
        gitlab: Service = Service(),
        bitbucket: Service = Service(),
        jira: Service = Service(),
        confluence: Service = Service()
    ) {
        self.github = github
        self.gitlab = gitlab
        self.bitbucket = bitbucket
        self.jira = jira
        self.confluence = confluence
    }

    public var anyEnabled: Bool {
        [github, gitlab, bitbucket, jira, confluence].contains { $0.enabled }
    }

    /// Slugs of enabled services, in bar order.
    public var enabledIDs: [String] {
        var ids: [String] = []
        if github.enabled { ids.append("github") }
        if gitlab.enabled { ids.append("gitlab") }
        if bitbucket.enabled { ids.append("bitbucket") }
        if jira.enabled { ids.append("jira") }
        if confluence.enabled { ids.append("confluence") }
        return ids
    }
}
