import Foundation

/// Pull requests awaiting your review, plus your own open PRs.
///
/// Credentials, in order: a token stored in the Keychain, else the `gh` CLI's
/// token — so anyone already signed into `gh` gets this with no setup.
public struct GitHubProvider: IntegrationProvider {
    public let id = "github"
    public let displayName = "GitHub"
    public let barLabel = "PR"
    private let host: String

    public init(host: String = "") {
        self.host = host.trimmingCharacters(in: .whitespaces)
    }

    private var apiBase: String {
        host.isEmpty ? "https://api.github.com" : "https://\(host)/api/v3"
    }

    public static func resolveToken() -> String? {
        if let stored = Keychain.token(for: "github") {
            return stored
        }
        return ghCLIToken()
    }

    /// `gh auth token` — zero-config credentials for anyone using the CLI.
    static func ghCLIToken() -> String? {
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        where FileManager.default.isExecutableFile(atPath: path) {
            let process = Process()
            process.executableURL = URL(filePath: path)
            process.arguments = ["auth", "token"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { continue }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { continue }
            let token = String(
                decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { return token }
        }
        return nil
    }

    public func fetch() async throws -> [IntegrationItem] {
        guard let token = Self.resolveToken() else {
            throw IntegrationError.missingCredentials(displayName)
        }
        // Two buckets, deduplicated: what needs *your* attention first.
        let queries: [(String, String)] = [
            ("review-requested:@me is:open is:pr", "review"),
            ("author:@me is:open is:pr", "mine"),
        ]
        var seen: Set<Int> = []
        var items: [IntegrationItem] = []
        for (query, badge) in queries {
            for issue in try await search(query: query, token: token) {
                guard seen.insert(issue.id).inserted, let url = URL(string: issue.html_url)
                else { continue }
                items.append(
                    IntegrationItem(
                        id: "github-\(issue.id)",
                        title: issue.title,
                        subtitle: Self.repository(from: issue.html_url),
                        badge: badge,
                        url: url))
            }
        }
        return items
    }

    private func search(query: String, token: String) async throws -> [SearchIssue] {
        var components = URLComponents(string: "\(apiBase)/search/issues")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "per_page", value: "25"),
            URLQueryItem(name: "sort", value: "updated"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Panewright", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw IntegrationError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message =
                (try? JSONDecoder().decode(APIError.self, from: data))?.message ?? ""
            throw IntegrationError.http(http.statusCode, message)
        }
        guard let result = try? JSONDecoder().decode(SearchResult.self, from: data) else {
            throw IntegrationError.malformedResponse
        }
        return result.items
    }

    /// "https://github.com/owner/repo/pull/12" → "owner/repo #12"
    static func repository(from htmlURL: String) -> String {
        let parts = htmlURL.split(separator: "/")
        guard parts.count >= 5 else { return "" }
        let owner = parts[2] == "github.com" ? parts[3] : parts[parts.count - 4]
        let repo = parts[parts.count - 3]
        let number = parts.last.map { "#\($0)" } ?? ""
        return "\(owner)/\(repo) \(number)"
    }

    private struct SearchResult: Decodable {
        let items: [SearchIssue]
    }

    struct SearchIssue: Decodable {
        let id: Int
        let title: String
        let html_url: String
    }

    private struct APIError: Decodable {
        let message: String
    }
}
