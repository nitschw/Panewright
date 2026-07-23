import Foundation

/// Unresolved issues assigned to you, newest first — the JQL this was
/// modeled on. Jira Cloud authenticates with email + API token (basic);
/// Server/Data Center accepts a bearer PAT, so both are tried.
public struct JiraProvider: IntegrationProvider {
    public let id = "jira"
    public let displayName = "Jira"
    public let barLabel = "JIRA"
    private let host: String
    private let email: String

    public init(host: String, email: String) {
        self.host = host.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        self.email = email.trimmingCharacters(in: .whitespaces)
    }

    public static let defaultJQL =
        "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC"

    public func fetch() async throws -> [IntegrationItem] {
        guard !host.isEmpty else {
            throw IntegrationError.missingCredentials("\(displayName) host")
        }
        guard let token = Keychain.token(for: "jira") else {
            throw IntegrationError.missingCredentials(displayName)
        }
        let response = try await search(token: token)
        return response.issues.compactMap { issue in
            guard let url = URL(string: "https://\(host)/browse/\(issue.key)") else {
                return nil
            }
            let status = issue.fields.status?.name ?? ""
            let priority = issue.fields.priority?.name
            let subtitle = [issue.key, status, priority].compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            return IntegrationItem(
                id: "jira-\(issue.key)",
                title: issue.fields.summary,
                subtitle: subtitle,
                badge: status.isEmpty ? nil : status.lowercased(),
                url: url)
        }
    }

    /// Atlassian moved search to /search/jql on Cloud; fall back to the
    /// classic endpoint for older sites.
    private func search(token: String) async throws -> SearchResponse {
        var lastError: Error = IntegrationError.malformedResponse
        for path in ["/rest/api/3/search/jql", "/rest/api/3/search"] {
            do {
                return try await request(path: path, token: token)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func request(path: String, token: String) async throws -> SearchResponse {
        var components = URLComponents(string: "https://\(host)\(path)")!
        components.queryItems = [
            URLQueryItem(name: "jql", value: Self.defaultJQL),
            URLQueryItem(name: "maxResults", value: "50"),
            URLQueryItem(name: "fields", value: "summary,status,priority"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        if email.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            let credentials = Data("\(email):\(token)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw IntegrationError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw IntegrationError.http(http.statusCode, "")
        }
        guard let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data) else {
            throw IntegrationError.malformedResponse
        }
        return decoded
    }

    struct SearchResponse: Decodable {
        let issues: [Issue]
    }

    struct Issue: Decodable {
        let key: String
        let fields: Fields

        struct Fields: Decodable {
            let summary: String
            let status: Named?
            let priority: Named?
        }

        struct Named: Decodable {
            let name: String
        }
    }
}
