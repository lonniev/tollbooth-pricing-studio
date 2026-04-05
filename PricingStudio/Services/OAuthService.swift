import Foundation
import AuthenticationServices
import CryptoKit

/// Persisted token bundle with refresh capability.
struct TokenBundle: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let tokenEndpoint: String
    let clientId: String
    let clientSecret: String?

    /// Returns true if the token has expired (with a 60-second safety margin).
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt.addingTimeInterval(-60)
    }
}

@MainActor
final class OAuthService: NSObject, Sendable {

    private static let callbackScheme = "com.tollbooth.dpyc.pricingstudio"
    private static let callbackURL = "com.tollbooth.dpyc.pricingstudio://oauth/callback"

    struct OAuthMetadata: Codable {
        let authorization_endpoint: String
        let token_endpoint: String
        let registration_endpoint: String?
    }

    struct ClientRegistration: Codable {
        let client_id: String
        let client_secret: String?
    }

    struct TokenResponse: Codable {
        let access_token: String
        let token_type: String
        let expires_in: Int?
        let refresh_token: String?
    }

    func authenticate(mcpEndpoint: URL) async throws -> TokenBundle {
        let metadata: OAuthMetadata
        do {
            metadata = try await discoverMetadata(for: mcpEndpoint)
        } catch OAuthError.metadataFetchFailed {
            // No OAuth on this endpoint — return an empty bundle (no auth needed)
            return TokenBundle(
                accessToken: "",
                refreshToken: nil,
                expiresAt: Date.distantFuture,
                tokenEndpoint: "",
                clientId: "",
                clientSecret: ""
            )
        }
        let registration = try await registerClient(metadata: metadata, endpoint: mcpEndpoint)
        let (codeVerifier, codeChallenge) = generatePKCE()
        let authCode = try await requestAuthorization(
            metadata: metadata,
            clientId: registration.client_id,
            codeChallenge: codeChallenge
        )
        let tokenResponse = try await exchangeCode(
            authCode: authCode,
            metadata: metadata,
            clientId: registration.client_id,
            clientSecret: registration.client_secret,
            codeVerifier: codeVerifier
        )
        return TokenBundle(
            accessToken: tokenResponse.access_token,
            refreshToken: tokenResponse.refresh_token,
            expiresAt: tokenResponse.expires_in.map { Date().addingTimeInterval(TimeInterval($0)) },
            tokenEndpoint: metadata.token_endpoint,
            clientId: registration.client_id,
            clientSecret: registration.client_secret
        )
    }

    /// Attempt to refresh an expired token using the stored refresh_token.
    func refresh(bundle: TokenBundle) async throws -> TokenBundle {
        guard let refreshToken = bundle.refreshToken else {
            throw OAuthError.noRefreshToken
        }
        guard let tokenURL = URL(string: bundle.tokenEndpoint) else {
            throw OAuthError.invalidEndpoint
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var params = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": bundle.clientId,
        ]
        if let secret = bundle.clientSecret {
            params["client_secret"] = secret
        }
        let body = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)

        let urlString = tokenURL.absoluteString
        TrafficLogger.shared.logHTTP(
            label: "OAuth Token Refresh", method: "POST", url: urlString,
            requestHeaders: request.allHTTPHeaderFields ?? [:], requestBody: "grant_type=refresh_token&client_id=\(bundle.clientId)"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 0
        let respHeaders = (httpResponse?.allHeaderFields as? [String: String]) ?? [:]
        let bodyText = String(data: data.prefix(2000), encoding: .utf8) ?? "<\(data.count) bytes>"

        guard statusCode == 200 else {
            TrafficLogger.shared.logHTTP(
                label: "OAuth Token Refresh Failed", method: "POST", url: urlString,
                statusCode: statusCode, responseHeaders: respHeaders, responseBody: bodyText,
                error: "HTTP \(statusCode)"
            )
            throw OAuthError.refreshFailed
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        TrafficLogger.shared.logHTTP(
            label: "OAuth Token Refreshed", method: "POST", url: urlString,
            statusCode: 200, responseHeaders: respHeaders,
            responseBody: "token_type: \(tokenResponse.token_type), expires_in: \(tokenResponse.expires_in ?? -1)"
        )

        return TokenBundle(
            accessToken: tokenResponse.access_token,
            refreshToken: tokenResponse.refresh_token ?? bundle.refreshToken,
            expiresAt: tokenResponse.expires_in.map { Date().addingTimeInterval(TimeInterval($0)) },
            tokenEndpoint: bundle.tokenEndpoint,
            clientId: bundle.clientId,
            clientSecret: bundle.clientSecret
        )
    }

    private func discoverMetadata(for endpoint: URL) async throws -> OAuthMetadata {
        guard let host = endpoint.host, let scheme = endpoint.scheme else {
            throw OAuthError.invalidEndpoint
        }
        let metadataURL = URL(string: "\(scheme)://\(host)/.well-known/oauth-authorization-server")!
        let urlString = metadataURL.absoluteString
        TrafficLogger.shared.logHTTP(label: "OAuth Discovery", method: "GET", url: urlString)
        let (data, response) = try await URLSession.shared.data(from: metadataURL)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 0
        let respHeaders = (httpResponse?.allHeaderFields as? [String: String]) ?? [:]
        let bodyText = String(data: data.prefix(2000), encoding: .utf8) ?? "<\(data.count) bytes>"
        guard statusCode == 200 else {
            TrafficLogger.shared.logHTTP(
                label: "OAuth Discovery Failed", method: "GET", url: urlString,
                statusCode: statusCode, responseHeaders: respHeaders, responseBody: bodyText,
                error: "HTTP \(statusCode)"
            )
            throw OAuthError.metadataFetchFailed
        }
        let metadata = try JSONDecoder().decode(OAuthMetadata.self, from: data)
        TrafficLogger.shared.logHTTP(
            label: "OAuth Metadata", method: "GET", url: urlString,
            statusCode: 200, responseHeaders: respHeaders, responseBody: bodyText
        )
        return metadata
    }

    private func registerClient(metadata: OAuthMetadata, endpoint: URL) async throws -> ClientRegistration {
        guard let registrationEndpoint = metadata.registration_endpoint,
              let url = URL(string: registrationEndpoint) else {
            throw OAuthError.registrationNotSupported
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "client_name": "Pricing Studio",
            "redirect_uris": [Self.callbackURL],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "client_secret_post"
        ]
        let reqBody = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = reqBody
        let urlString = url.absoluteString
        let reqHeaders = request.allHTTPHeaderFields ?? [:]
        let reqBodyText = String(data: reqBody, encoding: .utf8) ?? ""
        TrafficLogger.shared.logHTTP(
            label: "OAuth Register Client", method: "POST", url: urlString,
            requestHeaders: reqHeaders, requestBody: reqBodyText
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 0
        let respHeaders = (httpResponse?.allHeaderFields as? [String: String]) ?? [:]
        let bodyText = String(data: data.prefix(2000), encoding: .utf8) ?? "<\(data.count) bytes>"
        guard statusCode == 201 || statusCode == 200 else {
            TrafficLogger.shared.logHTTP(
                label: "OAuth Registration Failed", method: "POST", url: urlString,
                requestHeaders: reqHeaders, requestBody: reqBodyText,
                statusCode: statusCode, responseHeaders: respHeaders, responseBody: bodyText,
                error: "HTTP \(statusCode)"
            )
            throw OAuthError.registrationFailed
        }
        let registration = try JSONDecoder().decode(ClientRegistration.self, from: data)
        TrafficLogger.shared.logHTTP(
            label: "OAuth Client Registered", method: "POST", url: urlString,
            requestHeaders: reqHeaders, requestBody: reqBodyText,
            statusCode: statusCode, responseHeaders: respHeaders, responseBody: bodyText
        )
        return registration
    }

    private func generatePKCE() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let challengeData = Data(SHA256.hash(data: Data(verifier.utf8)))
        let challenge = challengeData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return (verifier, challenge)
    }

    private func requestAuthorization(
        metadata: OAuthMetadata,
        clientId: String,
        codeChallenge: String
    ) async throws -> String {
        guard let authEndpoint = URL(string: metadata.authorization_endpoint) else {
            throw OAuthError.invalidEndpoint
        }
        var components = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: Self.callbackURL),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        let authURL = components.url!
        TrafficLogger.shared.log(.outbound, label: "OAuth Browser Opening", detail: "Presenting auth session → \(authURL.absoluteString)")
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: Self.callbackScheme
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: OAuthError.authSessionFailed(error))
                    return
                }
                guard let callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                    continuation.resume(throwing: OAuthError.noAuthCode)
                    return
                }
                continuation.resume(returning: code)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    private func exchangeCode(
        authCode: String,
        metadata: OAuthMetadata,
        clientId: String,
        clientSecret: String?,
        codeVerifier: String
    ) async throws -> TokenResponse {
        guard let tokenURL = URL(string: metadata.token_endpoint) else {
            throw OAuthError.invalidEndpoint
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var params = [
            "grant_type": "authorization_code",
            "code": authCode,
            "redirect_uri": Self.callbackURL,
            "client_id": clientId,
            "code_verifier": codeVerifier,
        ]
        if let secret = clientSecret {
            params["client_secret"] = secret
        }
        let body = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)
        let urlString = tokenURL.absoluteString
        let reqHeaders = request.allHTTPHeaderFields ?? [:]
        // Redact code_verifier from logged body
        let safeBody = body.replacingOccurrences(of: codeVerifier, with: "<redacted>")
        TrafficLogger.shared.logHTTP(
            label: "OAuth Token Exchange", method: "POST", url: urlString,
            requestHeaders: reqHeaders, requestBody: safeBody
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 0
        let respHeaders = (httpResponse?.allHeaderFields as? [String: String]) ?? [:]
        let bodyText = String(data: data.prefix(2000), encoding: .utf8) ?? "<\(data.count) bytes>"
        guard statusCode == 200 else {
            TrafficLogger.shared.logHTTP(
                label: "OAuth Token Exchange Failed", method: "POST", url: urlString,
                requestHeaders: reqHeaders, requestBody: safeBody,
                statusCode: statusCode, responseHeaders: respHeaders, responseBody: bodyText,
                error: "HTTP \(statusCode) — \(bodyText)"
            )
            throw OAuthError.tokenExchangeFailed
        }
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        // Don't log the actual access_token
        TrafficLogger.shared.logHTTP(
            label: "OAuth Token Received", method: "POST", url: urlString,
            requestHeaders: reqHeaders,
            statusCode: 200, responseHeaders: respHeaders,
            responseBody: "token_type: \(tokenResponse.token_type), expires_in: \(tokenResponse.expires_in ?? -1)"
        )
        return tokenResponse
    }
}

extension OAuthService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
            ?? ASPresentationAnchor()
    }
}

enum OAuthError: LocalizedError {
    case invalidEndpoint
    case metadataFetchFailed
    case registrationNotSupported
    case registrationFailed
    case authSessionFailed(Error)
    case noAuthCode
    case tokenExchangeFailed
    case noRefreshToken
    case refreshFailed

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Invalid OAuth endpoint"
        case .metadataFetchFailed: return "Failed to fetch OAuth metadata"
        case .registrationNotSupported: return "Dynamic client registration not supported"
        case .registrationFailed: return "OAuth client registration failed"
        case .authSessionFailed(let error):
            let desc = error.localizedDescription
            if desc.contains("cancel") || desc.contains("Cancel") {
                return "Sign-in required — tap an operator to authenticate with Horizon."
            }
            return "Authentication failed: \(desc)"
        case .noAuthCode: return "No authorization code received"
        case .tokenExchangeFailed: return "Failed to exchange authorization code for token"
        case .noRefreshToken: return "No refresh token available"
        case .refreshFailed: return "Token refresh failed"
        }
    }
}
