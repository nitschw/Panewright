import Foundation

/// Merge requests you opened and ones assigned to you, with the head
/// pipeline's status as a colored bubble — mirroring the dashboard query
/// this was modeled on.
public struct GitLabProvider: IntegrationProvider {
    public let id = "gitlab"
    public let displayName = "GitLab"
    public let barLabel = "MR"
    private let host: String

    public init(host: String) {
        self.host = host.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    /// Pipeline status → bubble, same vocabulary as the GitLab UI.
    static let pipelineDot: [String: String] = [
        "success": "🟢", "failed": "🔴", "running": "🔵", "pending": "🟡",
        "preparing": "🟡", "waiting_for_resource": "🟡", "created": "⚪",
        "manual": "⚪", "scheduled": "🟣", "canceled": "⚫", "skipped": "⚪",
    ]

    /// Detail lookups are one request per MR, so cap how many we decorate.
    private static let pipelineLookupLimit = 12

    public func fetch() async throws -> [IntegrationItem] {
        guard !host.isEmpty else {
            throw IntegrationError.missingCredentials("\(displayName) host")
        }
        guard let token = Keychain.token(for: "gitlab") else {
            throw IntegrationError.missingCredentials(displayName)
        }
        var seen: Set<Int> = []
        var merged: [(MergeRequest, String)] = []
        for (scope, badge) in [("created_by_me", "mine"), ("assigned_to_me", "review")] {
            let path =
                "/merge_requests?scope=\(scope)&state=opened&per_page=25"
                + "&order_by=updated_at&sort=desc"
            for mr in try await get([MergeRequest].self, path: path, token: token)
            where seen.insert(mr.id).inserted {
                merged.append((mr, badge))
            }
        }

        let pipelines = await pipelineStatuses(for: merged.prefix(Self.pipelineLookupLimit).map(\.0), token: token)
        return merged.compactMap { mr, badge in
            guard let url = URL(string: mr.web_url) else { return nil }
            let project = mr.references?.full?.components(separatedBy: "!").first ?? ""
            let dot = pipelines[mr.id].map { " \($0)" } ?? ""
            return IntegrationItem(
                id: "gitlab-\(mr.id)",
                title: mr.title,
                subtitle: "\(project) !\(mr.iid)\(dot)",
                badge: badge,
                url: url)
        }
    }

    private func pipelineStatuses(
        for requests: [MergeRequest], token: String
    ) async -> [Int: String] {
        await withTaskGroup(of: (Int, String?).self) { group in
            for mr in requests {
                group.addTask {
                    let detail = try? await get(
                        MergeRequestDetail.self,
                        path: "/projects/\(mr.project_id)/merge_requests/\(mr.iid)",
                        token: token)
                    let status = detail?.head_pipeline?.status
                    return (mr.id, status.flatMap { Self.pipelineDot[$0] ?? "⚪" })
                }
            }
            var result: [Int: String] = [:]
            for await (id, dot) in group {
                if let dot { result[id] = dot }
            }
            return result
        }
    }

    private func get<T: Decodable>(_ type: T.Type, path: String, token: String) async throws -> T {
        guard let url = URL(string: "https://\(host)/api/v4\(path)") else {
            throw IntegrationError.malformedResponse
        }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        request.timeoutInterval = 20
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

    struct MergeRequest: Decodable {
        let id: Int
        let iid: Int
        let project_id: Int
        let title: String
        let web_url: String
        let references: References?

        struct References: Decodable {
            let full: String?
        }
    }

    private struct MergeRequestDetail: Decodable {
        let head_pipeline: Pipeline?

        struct Pipeline: Decodable {
            let status: String
        }
    }
}
