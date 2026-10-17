import CryptoKit
import Foundation

/// This device's OAuth tokens on one operator host.
struct HolderTokens: Codable, Sendable {
    let clientID: String
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date

    /// True within a minute of lapsing, so a request never leaves with a dead token.
    var isLapsing: Bool { Date() >= expiresAt.addingTimeInterval(-60) }
}

/// Studio as a *holder* on an operator: a connection the operator knows, into
/// whose wallet an npub is proven by the Secure Courier DM. Studio uses it for
/// an npub whose nsec it does not hold, and keeps only the connection's OAuth
/// tokens, in the Keychain per host.
///
/// Becoming a holder is the OAuth Authorization Code flow run headless: the
/// operator's `/authorize` approves at once (a holder holds nothing until a DM
/// proves an npub into it), so Studio reads the code off the redirect instead
/// of opening a browser. A refresh token is single-use, so the refreshes for
/// one host run one at a time and each stores the pair it returns.
actor HolderConnection {

    static let shared = HolderConnection()

    static let redirectURI = "http://127.0.0.1/holder"

    enum HolderError: LocalizedError {
        case refused(Int)
        case noRedirect
        case mismatchedReply

        var errorDescription: String? {
            switch self {
            case .refused(let status): return "The operator refused this connection (\(status))."
            case .noRedirect: return "The operator did not send the connection back."
            case .mismatchedReply: return "The operator's reply did not match this connection."
            }
        }
    }

    private var inFlight: [String: Task<HolderTokens, Error>] = [:]

    /// The bearer for the next request to `endpoint`'s operator: refreshed when
    /// it is about to lapse, or a fresh connection when there is none.
    func bearer(for endpoint: URL) async throws -> String {
        let root = Self.root(of: endpoint)
        let host = root.host ?? root.absoluteString
        if let held = KeychainService.loadHolderTokens(forHost: host), !held.isLapsing {
            return held.accessToken
        }
        if let running = inFlight[host] {
            return try await running.value.accessToken
        }
        let task = Task { try await Self.renew(root: root, host: host) }
        inFlight[host] = task
        defer { inFlight[host] = nil }
        return try await task.value.accessToken
    }

    private static func renew(root: URL, host: String) async throws -> HolderTokens {
        var fresh: HolderTokens?
        if let held = KeychainService.loadHolderTokens(forHost: host) {
            fresh = try? await token(root: root, clientID: held.clientID, form: [
                "grant_type": "refresh_token", "refresh_token": held.refreshToken,
            ])
        }
        let tokens: HolderTokens
        if let fresh {
            tokens = fresh
        } else {
            tokens = try await connect(root: root)
        }
        try KeychainService.saveHolderTokens(tokens, forHost: host)
        return tokens
    }

    private static func connect(root: URL) async throws -> HolderTokens {
        let registration = try await post(root.appending(path: "register"), json: [
            "client_name": "Pricing Studio",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])
        guard let clientID = registration["client_id"] as? String else { throw HolderError.mismatchedReply }

        let verifier = base64url(Data((0..<48).map { _ in UInt8.random(in: .min ... .max) }))
        let state = base64url(Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }))
        var authorize = URLComponents(url: root.appending(path: "authorize"), resolvingAgainstBaseURL: false)!
        authorize.queryItems = [
            "response_type": "code", "client_id": clientID, "redirect_uri": redirectURI, "state": state,
            "code_challenge": base64url(Data(SHA256.hash(data: Data(verifier.utf8)))),
            "code_challenge_method": "S256", "resource": resource(root),
        ].map { URLQueryItem(name: $0.key, value: $0.value) }

        let (_, response) = try await URLSession.shared.data(from: authorize.url!, delegate: KeepRedirect())
        guard let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
              let back = URLComponents(string: location) else { throw HolderError.noRedirect }
        let reply = Dictionary(back.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { a, _ in a })
        guard reply["state"] == state, let code = reply["code"], !code.isEmpty else { throw HolderError.mismatchedReply }

        return try await token(root: root, clientID: clientID, form: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI, "code_verifier": verifier,
        ])
    }

    private static func token(root: URL, clientID: String, form: [String: String]) async throws -> HolderTokens {
        var body = URLComponents()
        body.queryItems = form.merging(["client_id": clientID, "resource": resource(root)]) { a, _ in a }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: root.appending(path: "token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((body.percentEncodedQuery ?? "").utf8)
        let reply = try await send(request)
        guard let access = reply["access_token"] as? String, let refresh = reply["refresh_token"] as? String else {
            throw HolderError.mismatchedReply
        }
        let lifetime = (reply["expires_in"] as? Double) ?? 3600
        return HolderTokens(clientID: clientID, accessToken: access, refreshToken: refresh,
                            expiresAt: Date().addingTimeInterval(lifetime))
    }

    private static func post(_ url: URL, json: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await send(request)
    }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HolderError.refused(status) }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// The operator's origin: `/register`, `/authorize` and `/token` live at its root.
    static func root(of endpoint: URL) -> URL {
        var parts = URLComponents()
        parts.scheme = endpoint.scheme
        parts.host = endpoint.host
        parts.port = endpoint.port
        return parts.url ?? endpoint
    }

    private static func resource(_ root: URL) -> String { root.appending(path: "mcp").absoluteString }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Stops at the operator's redirect so its `Location` can be read.
private final class KeepRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
