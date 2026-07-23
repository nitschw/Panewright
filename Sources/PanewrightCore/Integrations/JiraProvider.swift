import Foundation

/// One issue in the hierarchy, with whatever hangs beneath it.
public struct JiraIssueNode: Sendable, Equatable, Identifiable {
    public var id: String { key }
    public var key: String
    public var summary: String
    public var status: String
    public var type: String
    public var url: URL
    /// Assigned to you — highlighted so your work stands out in context.
    public var isMine: Bool
    public var children: [JiraIssueNode]

    public init(
        key: String, summary: String, status: String, type: String, url: URL,
        isMine: Bool, children: [JiraIssueNode]
    ) {
        self.key = key
        self.summary = summary
        self.status = status
        self.type = type
        self.url = url
        self.isMine = isMine
        self.children = children
    }

    /// Depth-first count including self — used for "n of yours" summaries.
    public var mineCount: Int {
        (isMine ? 1 : 0) + children.reduce(0) { $0 + $1.mineCount }
    }
}

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
            let subtitle = [issue.key, priority].compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            return IntegrationItem(
                id: "jira-\(issue.key)",
                title: issue.fields.summary,
                subtitle: subtitle,
                badge: status.isEmpty ? nil : status,
                url: url,
                status: status,
                priority: priority,
                updated: issue.fields.updated.flatMap(Self.parseDate))
        }
    }

    /// Your issues placed in context: each one's ancestors (epic, parent
    /// story) and its subtasks, so you can see how today's work ladders up.
    public func hierarchy() async throws -> [JiraIssueNode] {
        guard !host.isEmpty else {
            throw IntegrationError.missingCredentials("\(displayName) host")
        }
        guard let token = Keychain.token(for: "jira") else {
            throw IntegrationError.missingCredentials(displayName)
        }
        let mine = try await search(jql: Self.defaultJQL, token: token).issues
        var byKey: [String: Issue] = [:]
        var mineKeys: Set<String> = []
        for issue in mine {
            byKey[issue.key] = issue
            mineKeys.insert(issue.key)
        }

        // Walk up: fetch ancestors we don't already have, a level at a time.
        var frontier = Set(mine.compactMap { $0.fields.parent?.key })
            .subtracting(byKey.keys)
        var depth = 0
        while !frontier.isEmpty, depth < 3 {
            depth += 1
            let keys = frontier.map { "\"\($0)\"" }.joined(separator: ",")
            let parents = try await search(jql: "key in (\(keys))", token: token).issues
            for issue in parents { byKey[issue.key] = issue }
            frontier = Set(parents.compactMap { $0.fields.parent?.key })
                .subtracting(byKey.keys)
        }

        // Children, then roots: anything whose parent isn't in the set.
        var childrenOf: [String: [String]] = [:]
        for issue in byKey.values {
            guard let parent = issue.fields.parent?.key, byKey[parent] != nil else { continue }
            childrenOf[parent, default: []].append(issue.key)
        }
        let roots = byKey.values
            .filter { issue in
                guard let parent = issue.fields.parent?.key else { return true }
                return byKey[parent] == nil
            }
            .map(\.key)
            .sorted()

        func node(_ key: String) -> JiraIssueNode? {
            guard let issue = byKey[key] else { return nil }
            var children = (childrenOf[key] ?? []).sorted().compactMap(node)
            // Subtasks arrive inline; include the ones we didn't fetch.
            for subtask in issue.fields.subtasks ?? []
            where byKey[subtask.key] == nil {
                children.append(
                    JiraIssueNode(
                        key: subtask.key,
                        summary: subtask.fields?.summary ?? "",
                        status: subtask.fields?.status?.name ?? "",
                        type: subtask.fields?.issuetype?.name ?? "Sub-task",
                        url: url(for: subtask.key),
                        isMine: false,
                        children: []))
            }
            return JiraIssueNode(
                key: issue.key,
                summary: issue.fields.summary,
                status: issue.fields.status?.name ?? "",
                type: issue.fields.issuetype?.name ?? "",
                url: url(for: issue.key),
                isMine: mineKeys.contains(issue.key),
                children: children)
        }
        return roots.compactMap(node)
    }

    private func url(for key: String) -> URL {
        URL(string: "https://\(host)/browse/\(key)")
            ?? URL(string: "https://\(host)")!
    }

    /// Atlassian moved search to /search/jql on Cloud; fall back to the
    /// classic endpoint for older sites.
    private func search(token: String) async throws -> SearchResponse {
        try await search(jql: Self.defaultJQL, token: token)
    }

    private func search(jql: String, token: String) async throws -> SearchResponse {
        var lastError: Error = IntegrationError.malformedResponse
        for path in ["/rest/api/3/search/jql", "/rest/api/3/search"] {
            do {
                return try await request(path: path, jql: jql, token: token)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func request(
        path: String, jql: String, token: String
    ) async throws -> SearchResponse {
        var components = URLComponents(string: "https://\(host)\(path)")!
        components.queryItems = [
            URLQueryItem(name: "jql", value: jql),
            URLQueryItem(name: "maxResults", value: "50"),
            URLQueryItem(
                name: "fields",
                value: "summary,status,priority,updated,parent,issuetype,subtasks"),
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

    /// Jira stamps look like 2026-07-23T01:22:33.000-0700.
    static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return ISO8601DateFormatter().date(from: value)
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
            let updated: String?
            let parent: Reference?
            let issuetype: Named?
            let subtasks: [Reference]?
        }

        struct Named: Decodable {
            let name: String
        }

        /// A linked issue: parents carry only a key; subtasks inline some
        /// fields.
        struct Reference: Decodable {
            let key: String
            let fields: SubFields?

            struct SubFields: Decodable {
                let summary: String?
                let status: Named?
                let issuetype: Named?
            }
        }
    }
}
