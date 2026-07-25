import CryptoKit
import Foundation

/// OAuth 2.0 (authorization code + PKCE) against Microsoft identity platform —
/// the sign-in half of the Teams/Microsoft 365 integration.
///
/// PKCE with a *public* client means no client secret ever ships in the app or
/// sits in a config file. Sign-in happens in the system browser, so an existing
/// Microsoft session, MFA, and conditional-access policies all work — real SSO
/// rather than a password prompt we'd have to be trusted with.
public enum MicrosoftAuth {
    /// Keychain account holding the JSON token bundle.
    public static let keychainAccount = "teams"
    /// Panewright's own URL scheme doubles as the OAuth redirect.
    public static let redirectURI = "panewright://msauth"

    public static let scopes = [
        "offline_access",  // refresh tokens, so sign-in survives restarts
        "User.Read",
        "Calendars.Read",
    ]

    /// `common` accepts any work/school or personal account; a specific tenant
    /// GUID locks sign-in to one organization.
    public static func authority(tenant: String) -> String {
        let t = tenant.trimmingCharacters(in: .whitespaces)
        return "https://login.microsoftonline.com/\(t.isEmpty ? "common" : t)"
    }

    // MARK: PKCE

    public struct PKCE: Equatable, Sendable {
        public let verifier: String
        public let challenge: String
    }

    /// RFC 7636: a high-entropy verifier, and its S256 challenge.
    public static func makePKCE() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = base64URL(Data(bytes))
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        return PKCE(verifier: verifier, challenge: challenge)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The URL to open in the browser to start sign-in.
    public static func authorizeURL(clientID: String, tenant: String, pkce: PKCE, state: String)
        -> URL?
    {
        var components = URLComponents(string: authority(tenant: tenant) + "/oauth2/v2.0/authorize")
        components?.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_mode", value: "query"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        return components?.url
    }

    // MARK: Tokens

    public struct Tokens: Codable, Equatable, Sendable {
        public var accessToken: String
        public var refreshToken: String
        /// Absolute expiry, so a restart can tell a stale token from a live one.
        public var expiresAt: Date

        public var isExpired: Bool {
            // Refresh a minute early rather than racing the boundary.
            Date() >= expiresAt.addingTimeInterval(-60)
        }
    }

    public static func loadTokens() -> Tokens? {
        guard let raw = Keychain.token(for: keychainAccount),
            let data = raw.data(using: .utf8),
            let tokens = try? JSONDecoder().decode(Tokens.self, from: data)
        else { return nil }
        return tokens
    }

    @discardableResult
    public static func store(_ tokens: Tokens?) -> Bool {
        guard let tokens else { return Keychain.setToken(nil, for: keychainAccount) }
        guard let data = try? JSONEncoder().encode(tokens),
            let json = String(data: data, encoding: .utf8)
        else { return false }
        return Keychain.setToken(json, for: keychainAccount)
    }

    /// Exchanges an authorization code (or a refresh token) for tokens.
    public static func requestTokens(
        clientID: String, tenant: String, grant: Grant, session: URLSession = .shared
    ) async throws -> Tokens {
        var request = URLRequest(url: URL(string: authority(tenant: tenant) + "/oauth2/v2.0/token")!)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var fields: [String: String] = [
            "client_id": clientID,
            "scope": scopes.joined(separator: " "),
        ]
        switch grant {
        case .authorizationCode(let code, let verifier):
            fields["grant_type"] = "authorization_code"
            fields["code"] = code
            fields["redirect_uri"] = redirectURI
            fields["code_verifier"] = verifier
        case .refresh(let token):
            fields["grant_type"] = "refresh_token"
            fields["refresh_token"] = token
        }
        request.httpBody = Data(
            fields.map { "\($0.key)=\(urlEncode($0.value))" }.joined(separator: "&").utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            // Microsoft returns a JSON error description worth surfacing.
            let detail =
                (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?[
                    "error_description"] as? String
            throw IntegrationError.http(code, detail ?? "sign-in failed")
        }
        struct Response: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return Tokens(
            accessToken: decoded.access_token,
            // A refresh response may omit the refresh token; keep the old one.
            refreshToken: decoded.refresh_token ?? grant.existingRefreshToken ?? "",
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in)))
    }

    public enum Grant: Sendable {
        case authorizationCode(code: String, verifier: String)
        case refresh(token: String)

        var existingRefreshToken: String? {
            if case .refresh(let token) = self { return token }
            return nil
        }
    }

    /// A valid access token, refreshing transparently when the stored one has
    /// aged out. Returns nil when the user has never signed in.
    public static func validAccessToken(clientID: String, tenant: String) async -> String? {
        guard let tokens = loadTokens() else { return nil }
        guard tokens.isExpired else { return tokens.accessToken }
        guard !tokens.refreshToken.isEmpty,
            let refreshed = try? await requestTokens(
                clientID: clientID, tenant: tenant, grant: .refresh(token: tokens.refreshToken))
        else { return nil }
        store(refreshed)
        return refreshed.accessToken
    }

    static func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
