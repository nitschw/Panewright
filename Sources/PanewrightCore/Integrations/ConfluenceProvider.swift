import Foundation

/// A Confluence page: metadata plus its rendered body.
public struct ConfluencePage: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var space: String
    public var url: URL
    /// Rendered HTML (`body.view`), empty until the page itself is fetched.
    public var html: String
    /// Who touched it last, and when — the activity view is built on these.
    public var lastEditor: String
    public var updated: Date?
    public var created: Date?

    public init(
        id: String,
        title: String,
        space: String,
        url: URL,
        html: String = "",
        lastEditor: String = "",
        updated: Date? = nil,
        created: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.space = space
        self.url = url
        self.html = html
        self.lastEditor = lastEditor
        self.updated = updated
        self.created = created
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

    public var siteHost: String { host }

    /// Shared with the reader so it can authenticate image requests.
    public func authorizationHeader() -> String? {
        guard let token = Keychain.token(for: "confluence") else { return nil }
        if email.isEmpty {
            return "Bearer \(token)"
        }
        return "Basic " + Data("\(email):\(token)".utf8).base64EncodedString()
    }

    /// Which field a query applies to.
    public enum SearchScope: String, Sendable, CaseIterable, Identifiable {
        case all = "All"
        case title = "Title"
        case content = "Content"
        case author = "Author"

        public var id: String { rawValue }
    }

    /// Builds the CQL for a scoped query. Author isn't expressible in CQL
    /// as free text (it wants account IDs), so it fetches recent pages and
    /// filters by editor name in ``search(_:scope:limit:)``.
    static func cql(for query: String, scope: SearchScope) -> String {
        let escaped = query.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        guard !escaped.isEmpty, scope != .author else {
            return "type = page order by lastmodified desc"
        }
        let predicate =
            switch scope {
            case .title: "title ~ \"\(escaped)\""
            case .content: "text ~ \"\(escaped)\""
            case .all, .author: "(title ~ \"\(escaped)\" or text ~ \"\(escaped)\")"
            }
        return "type = page and \(predicate) order by lastmodified desc"
    }

    /// Empty query returns what the workspace touched most recently.
    public func search(
        _ query: String, scope: SearchScope = .all, limit: Int = 30
    ) async throws -> [ConfluencePage] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let isAuthorSearch = scope == .author && !trimmed.isEmpty
        var components = URLComponents(string: "https://\(host)/wiki/rest/api/content/search")!
        components.queryItems = [
            URLQueryItem(name: "cql", value: Self.cql(for: trimmed, scope: scope)),
            // Author filtering happens locally, so cast a wider net first.
            URLQueryItem(name: "limit", value: "\(isAuthorSearch ? 100 : limit)"),
            URLQueryItem(name: "expand", value: "space,version,history"),
        ]
        let response: SearchResponse = try await get(components.url!)
        let pages = response.results.compactMap(page(from:))
        guard isAuthorSearch else { return pages }
        return pages.filter {
            $0.lastEditor.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Full rendered body for the reader.
    public func page(id: String) async throws -> ConfluencePage {
        var components = URLComponents(string: "https://\(host)/wiki/rest/api/content/\(id)")!
        components.queryItems = [
            URLQueryItem(name: "expand", value: "body.view,space,version,history")
        ]
        let result: Content = try await get(components.url!)
        guard var page = page(from: result) else {
            throw IntegrationError.malformedResponse
        }
        page.html = await inliningImages(result.body?.view?.value ?? "")
        return page
    }

    /// Attachments need the same credentials as the API, and a locally
    /// rendered document can't supply them — so fetch each image here and
    /// embed it as a data URI. No auth, no custom schemes, no origin rules
    /// in the web view at all.
    func inliningImages(_ html: String, limit: Int = 25) async -> String {
        let references = Self.imageReferences(in: html).prefix(limit)
        Log.write("confluence: \(references.count) image(s) to inline")
        guard !references.isEmpty else { return html }
        let fetched = await withTaskGroup(of: (String, String?).self) { group in
            for reference in references {
                group.addTask { (reference.source, await self.dataURI(for: reference)) }
            }
            var result: [String: String] = [:]
            for await (source, uri) in group {
                if let uri { result[source] = uri }
            }
            return result
        }
        let sources = references
        Log.write("confluence: inlined \(fetched.count)/\(sources.count) image(s)")
        var output = html
        for (source, uri) in fetched {
            output = output.replacingOccurrences(of: "\"\(source)\"", with: "\"\(uri)\"")
            output = output.replacingOccurrences(of: "'\(source)'", with: "'\(uri)'")
        }
        return output
    }

    /// An image in the page: the exact `src` string (so it can be swapped
    /// for a data URI) plus, when derivable, the REST path that actually
    /// serves the bytes.
    public struct ImageReference: Equatable, Sendable {
        public var source: String
        public var downloadPath: String?
    }

    /// The `/wiki/download/...` URLs Confluence embeds are served by a
    /// servlet that rejects API tokens outright (401, always). The REST
    /// attachment endpoint does accept them, and the tag carries the two
    /// IDs needed to address it.
    static func imageReferences(in html: String) -> [ImageReference] {
        var found: [ImageReference] = []
        var seen: Set<String> = []
        for tag in html.components(separatedBy: "<img").dropFirst() {
            let head = String(tag.prefix(1600))
            func attribute(_ name: String) -> String? {
                guard let start = head.range(of: "\(name)=\""),
                    let end = head.range(of: "\"", range: start.upperBound..<head.endIndex)
                else { return nil }
                let value = String(head[start.upperBound..<end.lowerBound])
                return value.isEmpty ? nil : value
            }
            guard let source = attribute("src"), !source.hasPrefix("data:"),
                seen.insert(source).inserted
            else { continue }
            var path: String?
            if let attachment = attribute("data-linked-resource-id"),
                let container = attribute("data-linked-resource-container-id") {
                path = "/rest/api/content/\(container)/child/attachment/att\(attachment)/download"
            }
            found.append(ImageReference(source: source, downloadPath: path))
        }
        return found
    }

    /// Attribute values arrive HTML-escaped. Requesting them verbatim turns
    /// `&api=v2` into `&amp;api=v2`, so the download servlet never sees the
    /// flag that lets it accept API-token auth — and answers 401.
    static func decodingHTMLEntities(_ value: String) -> String {
        var result = value
        for (entity, character) in [
            ("&amp;", "&"), ("&#38;", "&"), ("&quot;", "\""), ("&#34;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"),
        ] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }

    private func dataURI(for reference: ImageReference) async -> String? {
        let decoded = Self.decodingHTMLEntities(reference.source)
        // Prefer the REST path; the embedded URL is a fallback for images
        // that don't carry attachment IDs (external or inline-rendered).
        let absolute =
            reference.downloadPath.map { "https://\(host)/wiki\($0)" }
            ?? (decoded.hasPrefix("http")
                ? decoded
                : "https://\(host)\(decoded.hasPrefix("/") ? "" : "/")\(decoded)")
        guard let url = URL(string: absolute) else {
            Log.write("confluence image: unparseable \(absolute.prefix(80))")
            return nil
        }
        guard url.host?.hasSuffix(host) == true else {
            Log.write("confluence image: off-site host \(url.host ?? "?") — skipped")
            return nil
        }
        guard let token = Keychain.token(for: "confluence") else {
            Log.write("confluence image: no token in Keychain")
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if email.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            let credentials = Data("\(email):\(token)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }
        do {
            // Attachment downloads redirect to Atlassian's media CDN, and
            // URLSession strips Authorization across hosts — this session
            // re-attaches it for the site's own domains.
            let session = URLSession(
                configuration: .ephemeral,
                delegate: RedirectAuthenticator(host: host, header: request.value(
                    forHTTPHeaderField: "Authorization")),
                delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? -1
            guard (200..<300).contains(status), data.count < 8_000_000 else {
                let body = String(decoding: data.prefix(220), as: UTF8.self)
                    .replacingOccurrences(of: "\n", with: " ")
                Log.write(
                    "confluence image: status=\(status) bytes=\(data.count) "
                        + "url=\(url.path.suffix(50)) body=\(body)")
                return nil
            }
            return "data:\(http?.mimeType ?? "image/png");base64,\(data.base64EncodedString())"
        } catch {
            Log.write("confluence image: \(error) url=\(url.path.suffix(60))")
            return nil
        }
    }

    private func page(from content: Content) -> ConfluencePage? {
        let path = content._links?.webui ?? ""
        guard let url = URL(string: "https://\(host)/wiki\(path)") else { return nil }
        return ConfluencePage(
            id: content.id,
            title: content.title,
            space: content.space?.name ?? content.space?.key ?? "",
            url: url,
            lastEditor: content.version?.by?.displayName ?? "",
            updated: content.version?.when.flatMap(Self.parseDate),
            created: content.history?.createdDate.flatMap(Self.parseDate))
    }

    /// Atlassian timestamps: 2026-07-23T01:22:33.000Z (and offset variants).
    public static func parseDate(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: value)
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
        let version: Version?
        let history: History?
        let _links: Links?

        struct Space: Decodable {
            let key: String?
            let name: String?
        }
        struct Person: Decodable {
            let displayName: String?
        }
        struct Version: Decodable {
            let when: String?
            let by: Person?
        }
        struct History: Decodable {
            let createdDate: String?
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

/// Keeps credentials attached when a download redirects within the site's
/// own domains (URLSession drops them on any cross-host hop).
final class RedirectAuthenticator: NSObject, URLSessionTaskDelegate, Sendable {
    private let host: String
    private let header: String?

    init(host: String, header: String?) {
        self.host = host
        self.header = header
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var followUp = request
        let target = request.url?.host ?? ""
        let sameSite = target == host || target.hasSuffix(".atlassian.net")
            || target.hasSuffix(".atlassian.com")
        if sameSite, let header, followUp.value(forHTTPHeaderField: "Authorization") == nil {
            followUp.setValue(header, forHTTPHeaderField: "Authorization")
        }
        Log.write("confluence image: redirect → \(target) auth=\(sameSite)")
        completionHandler(followUp)
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

    /// Favorites keep only stable metadata; activity fields are refetched.
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
