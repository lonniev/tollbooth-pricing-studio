import Foundation
import MCP
import AuthenticationServices
import UIKit

/// Persisted token bundle for Keychain storage.
struct TokenBundle: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let tokenEndpoint: String
    let clientId: String
    let clientSecret: String?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt.addingTimeInterval(-60)
    }
}

/// Bridges KeychainService to the MCP SDK's TokenStorage protocol.
/// One storage instance per host — tokens keyed by operator host.
final class KeychainTokenStorage: TokenStorage, @unchecked Sendable {
    private let host: String

    init(host: String) {
        self.host = host
    }

    func save(_ token: OAuthAccessToken) {
        let bundle = TokenBundle(
            accessToken: token.value,
            refreshToken: token.refreshToken,
            expiresAt: token.expiresAt,
            tokenEndpoint: token.authorizationServer?.absoluteString ?? "",
            clientId: "",
            clientSecret: nil
        )
        try? KeychainService.saveTokenBundle(bundle, forOperator: host)
    }

    func load() -> OAuthAccessToken? {
        guard let bundle = KeychainService.loadTokenBundle(forOperator: host),
              !bundle.isExpired,
              !bundle.accessToken.isEmpty else {
            return nil
        }
        return OAuthAccessToken(
            value: bundle.accessToken,
            tokenType: "Bearer",
            expiresAt: bundle.expiresAt,
            scopes: [],
            authorizationServer: bundle.tokenEndpoint.isEmpty ? nil : URL(string: bundle.tokenEndpoint),
            refreshToken: bundle.refreshToken
        )
    }

    func clear() {
        KeychainService.deleteTokenBundle(forOperator: host)
    }
}

/// Presents OAuth authorization URLs using ASWebAuthenticationSession.
final class ASWebAuthDelegate: NSObject, OAuthAuthorizationDelegate, @unchecked Sendable {

    nonisolated func presentAuthorizationURL(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                let delegate = SessionDelegate()
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: "com.tollbooth.dpyc.pricingstudio"
                ) { callbackURL, error in
                    if let callbackURL {
                        continuation.resume(returning: callbackURL)
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: URLError(.cancelled))
                    }
                }
                session.presentationContextProvider = delegate
                session.prefersEphemeralWebBrowserSession = false
                objc_setAssociatedObject(session, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
                session.start()
            }
        }
    }
}

/// Provides the presentation anchor for ASWebAuthenticationSession.
private final class SessionDelegate: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

/// Factory for creating an OAuthAuthorizer configured for DPYC MCPs.
/// The authorizer handles 401 challenges automatically — no proactive auth needed.
enum MCPAuthFactory {
    static func makeAuthorizer(for endpoint: URL) -> OAuthAuthorizer {
        let host = endpoint.host ?? endpoint.absoluteString
        let config = OAuthConfiguration(
            grantType: .authorizationCode,
            authentication: .none(clientID: "PricingStudio"),
            authorizationRedirectURI: URL(string: "com.tollbooth.dpyc.pricingstudio://callback")!,
            clientName: "PricingStudio",
            authorizationDelegate: ASWebAuthDelegate()
        )
        return OAuthAuthorizer(
            configuration: config,
            tokenStorage: KeychainTokenStorage(host: host)
        )
    }
}
