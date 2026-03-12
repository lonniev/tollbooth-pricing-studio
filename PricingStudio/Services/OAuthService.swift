import Foundation
import AuthenticationServices
import CryptoKit

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

    func authenticate(mcpEndpoint: URL) async throws -> String {
        let metadata = try await discoverMetadata(for: mcpEndpoint)
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
        return tokenResponse.access_token
    }

    private func discoverMetadata(for endpoint: URL) async throws -> OAuthMetadata {
        guard let host = endpoint.host, let scheme = endpoint.scheme else {
            throw OAuthError.invalidEndpoint
        }
        let metadataURL = URL(string: "\(scheme)://\(host)/.well-known/oauth-authorization-server")!
        let (data, response) = try await URLSession.shared.data(from: metadataURL)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw OAuthError.metadataFetchFailed
        }
        return try JSONDecoder().decode(OAuthMetadata.self, from: data)
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
            "grant_types": ["authorization_code"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "client_secret_post"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 201 || httpResponse.statusCode == 200 else {
            throw OAuthError.registrationFailed
        }
        return try JSONDecoder().decode(ClientRegistration.self, from: data)
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
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw OAuthError.tokenExchangeFailed
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }
}

extension OAuthService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        ASPresentationAnchor()
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

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Invalid OAuth endpoint"
        case .metadataFetchFailed: return "Failed to fetch OAuth metadata"
        case .registrationNotSupported: return "Dynamic client registration not supported"
        case .registrationFailed: return "OAuth client registration failed"
        case .authSessionFailed(let error): return "Authentication failed: \(error.localizedDescription)"
        case .noAuthCode: return "No authorization code received"
        case .tokenExchangeFailed: return "Failed to exchange authorization code for token"
        }
    }
}
