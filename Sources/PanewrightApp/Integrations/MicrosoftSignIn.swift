import AppKit
import AuthenticationServices
import PanewrightCore

/// Browser-based Microsoft sign-in for the Teams integration.
///
/// `ASWebAuthenticationSession` is the reason this is real SSO: it hands off to
/// the system browser, so an existing Microsoft session signs you straight in,
/// and MFA, passkeys, and conditional-access policies all work — Panewright
/// never sees a password. PKCE means no client secret has to ship in the app.
@MainActor
final class MicrosoftSignIn: NSObject {
    private var session: ASWebAuthenticationSession?

    /// Runs the full flow and stores tokens in the Keychain.
    func signIn(clientID: String, tenant: String) async throws {
        let pkce = MicrosoftAuth.makePKCE()
        let state = UUID().uuidString
        guard
            let url = MicrosoftAuth.authorizeURL(
                clientID: clientID, tenant: tenant, pkce: pkce, state: state)
        else { throw IntegrationError.malformedResponse }

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: "panewright"
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: IntegrationError.malformedResponse)
                }
            }
            session.presentationContextProvider = self
            // Use the browser's existing Microsoft session — that's the SSO part.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // Reject a response that didn't originate from this request.
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw IntegrationError.malformedResponse
        }
        if let error = items.first(where: { $0.name == "error_description" })?.value {
            throw IntegrationError.http(400, error)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw IntegrationError.malformedResponse
        }
        let tokens = try await MicrosoftAuth.requestTokens(
            clientID: clientID, tenant: tenant,
            grant: .authorizationCode(code: code, verifier: pkce.verifier))
        MicrosoftAuth.store(tokens)
    }

    static func signOut() {
        MicrosoftAuth.store(nil)
    }

    static var isSignedIn: Bool { MicrosoftAuth.loadTokens() != nil }
}

extension MicrosoftSignIn: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // LSUIElement app: there may be no window, so fall back to a transient
        // anchor rather than crashing on a force-unwrap.
        NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
    }
}
