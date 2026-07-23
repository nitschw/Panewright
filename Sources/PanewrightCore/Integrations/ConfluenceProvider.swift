import Foundation

/// A Confluence page: metadata plus its rendered body.
public struct ConfluencePage: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var space: String
    public var url: URL
    /// Rendered HTML (`body.view`), empty until the page itself is fetched.
    public var html: String

    public init(id: String, title: String, space: String, url: URL, html: String = "") {
        self.id = id
        self.title = title
        self.space = space
        self.url = url
        self.html = html
    }
}

/// Search and read Confluence. Unlike the list-shaped providers this one
/// backs a reader window, so it isn't an `IntegrationProvider`.
public struct ConfluenceProvider: Sendable {
    public let displayName = "Confluence"
    private let host: String
    private let email: String

    public init(host: String, email: String) {
        self.host = host.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        self.email = email.trimmingCharacters(in: .whitespaces)
    }

    public var isConfigured: Bool {
        !host.isEmpty && Keychain.hasToken(for: "confluence")
    }

    /// Free-text search; empty query returns what you touched most recently.
    public func search(_ query: String, limit: Int = 30) async throws -> [ConfluencePage] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\\\"")
        let cql =
            trimmed.isEmpty
            ? "type = page order by lastmodified desc"
            : "type = page and text ~ \"\(escaped)\" order by lastmodified desc"
        var components = URLComponents(string: "https://\(host)/wiki/rest/api/content/search")!
        components.queryItems = [
            URLQueryItem(name: "cql", value: cql),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "expand", value: "space"),
        ]
        let response: SearchResponse = try await get(components.url!)
        return response.results.compactMap(page(from:))
    }

    /// Full rendered body for the reader.
    public func page(id: String) async throws -> ConfluencePage {
        var components = URLComponents(string: "https://\(host)/wiki/rest/api/content/\(id)")!
        components.queryItems = [
            URLQueryItem(name: "expand", value: "body.view,space")
        ]
        let result: Content = try await get(components.url!)
        guard var page = page(from: result) else {
            throw IntegrationError.malformedResponse
        }
        page.html = result.body?.view?.value ?? ""
        return page
    }

    private func page(from content: Content) -> ConfluencePage? {
        let path = content._links?.webui ?? ""
        guard let url = URL(string: "https://\(host)/wiki\(path)") else { return nil }
        return ConfluencePage(
            id: content.id,
            title: content.title,
            space: content.space?.name ?? content.space?.key ?? "",
            url: url)
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        guard !host.isEmpty else {
            throw IntegrationError.missingCredentials("\(displayName) host")
        }
        guard let token = Keychain.token(for: "confluence") else {
            throw IntegrationError.missingCredentials(displayName)
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 25
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
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw IntegrationError.malformedResponse
        }
        return decoded
    }

    private struct SearchResponse: Decodable {
        let results: [Content]
    }

    private struct Content: Decodable {
        let id: String
        let title: String
        let space: Space?
        let body: Body?
        let _links: Links?

        struct Space: Decodable {
            let key: String?
            let name: String?
        }
        struct Body: Decodable {
            let view: Value?
            struct Value: Decodable { let value: String }
        }
        struct Links: Decodable {
            let webui: String?
        }
    }
}

/// Favorited pages, in a plain file so they outlive the app — same
/// philosophy as the to-do list.
public enum ConfluenceFavorites {
    public static func defaultURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appending(path: ".config/panewright/confluence-favorites.tsv")
    }

    public static func load(from url: URL) -> [ConfluencePage] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 4, let pageURL = URL(string: parts[3]) else { return nil }
            return ConfluencePage(
                id: parts[0], title: parts[1], space: parts[2], url: pageURL)
        }
    }

    public static func save(_ pages: [ConfluencePage], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = pages.map {
            [$0.id, $0.title, $0.space, $0.url.absoluteString]
                .map { $0.replacingOccurrences(of: "\t", with: " ") }
                .joined(separator: "\t")
        }.joined(separator: "\n")
        try (text.isEmpty ? "" : text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
