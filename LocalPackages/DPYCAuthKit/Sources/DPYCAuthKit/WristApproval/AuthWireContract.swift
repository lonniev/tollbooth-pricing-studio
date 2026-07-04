import Foundation

// Wrist Approval wire contract, FROZEN v1 (ratified 2026-07-03).
//
// Both messages travel as NIP-59 gift wraps (kind 1059 → kind-13 seal signed
// by the real sender → unsigned rumor). These types are the rumor payloads.
// The seal signature is the authorship proof; wrap/seal timestamps are fuzzed,
// so freshness derives ONLY from the explicit fields here.

// MARK: - Offer

/// One approval button the Operator authored: the label is the human
/// contract, `validSeconds` the machine one. A response can only ever
/// name an offer that was authored here — never a duration of its own.
public struct AuthOffer: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let validSeconds: Int

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case validSeconds = "valid_seconds"
    }

    public init(id: String, label: String, validSeconds: Int) {
        self.id = id
        self.label = label
        self.validSeconds = validSeconds
    }
}

// MARK: - auth-request (Operator → Patron, rumor kind 24135)

public struct AuthRequest: Codable, Sendable, Equatable {
    public static let wireType = "auth-request"

    public let v: Int
    public let type: String
    public let requestId: String
    public let operatorNpub: String
    public let operatorName: String
    public let dpopToken: String
    public let offers: [AuthOffer]
    public let defaultOffer: String
    public let nonce: String
    public let expiresAt: Int
    public let replyRelay: String

    enum CodingKeys: String, CodingKey {
        case v
        case type
        case requestId = "request_id"
        case operatorNpub = "operator_npub"
        case operatorName = "operator_name"
        case dpopToken = "dpop_token"
        case offers
        case defaultOffer = "default_offer"
        case nonce
        case expiresAt = "expires_at"
        case replyRelay = "reply_relay"
    }

    public init(
        requestId: String = UUID().uuidString.lowercased(),
        operatorNpub: String,
        operatorName: String,
        dpopToken: String,
        offers: [AuthOffer],
        defaultOffer: String,
        nonce: String? = nil,
        expiresAt: Int,
        replyRelay: String
    ) {
        self.v = 1
        self.type = Self.wireType
        self.requestId = requestId
        self.operatorNpub = operatorNpub
        self.operatorName = operatorName
        self.dpopToken = dpopToken
        self.offers = offers
        self.defaultOffer = defaultOffer
        self.nonce = nonce ?? Data(GiftWrap.generateRandomBytes(32)).hexString
        self.expiresAt = expiresAt
        self.replyRelay = replyRelay
    }

    /// Build the kind-24135 rumor carrying this request, p-tagged to the patron.
    public func rumor(
        operatorPubKeyHex: String,
        patronPubKeyHex: String,
        createdAt: Int? = nil
    ) throws -> NostrEvent {
        try NostrEvent.rumor(
            kind: .authRequest,
            content: AuthContentCodec.encode(self),
            tags: [["p", patronPubKeyHex]],
            publicKeyHex: operatorPubKeyHex,
            createdAt: createdAt
        )
    }

    /// Parse and validate a decrypted kind-24135 rumor.
    public init(rumor: NostrEvent) throws {
        guard rumor.kind == NostrEventKind.authRequest.rawValue else {
            throw AuthError.kindMismatch(expected: NostrEventKind.authRequest.rawValue, got: rumor.kind)
        }
        let decoded: AuthRequest = try AuthContentCodec.decode(rumor.content)
        guard decoded.type == Self.wireType else {
            throw AuthError.typeMismatch(decoded.type)
        }
        guard decoded.v == 1 else {
            throw AuthError.unsupportedVersion(decoded.v)
        }
        self = decoded
    }
}

// MARK: - auth-response (Patron → Operator, rumor kind 24136)

public struct AuthResponse: Codable, Sendable, Equatable {
    public static let wireType = "auth-response"

    /// The reserved `choice` value meaning explicit refusal.
    public static let rejectChoice = "reject"

    public let v: Int
    public let type: String
    public let requestId: String
    public let dpopToken: String
    public let choice: String
    public let nonce: String

    enum CodingKeys: String, CodingKey {
        case v
        case type
        case requestId = "request_id"
        case dpopToken = "dpop_token"
        case choice
        case nonce
    }

    public var isRejection: Bool { choice == Self.rejectChoice }

    /// Answer a request with a chosen offer id, or ``rejectChoice``.
    public init(request: AuthRequest, choice: String) {
        self.v = 1
        self.type = Self.wireType
        self.requestId = request.requestId
        self.dpopToken = request.dpopToken
        self.choice = choice
        self.nonce = request.nonce
    }

    /// Build the kind-24136 rumor carrying this response, p-tagged to the operator.
    public func rumor(
        patronPubKeyHex: String,
        operatorPubKeyHex: String,
        createdAt: Int? = nil
    ) throws -> NostrEvent {
        try NostrEvent.rumor(
            kind: .authResponse,
            content: AuthContentCodec.encode(self),
            tags: [["p", operatorPubKeyHex]],
            publicKeyHex: patronPubKeyHex,
            createdAt: createdAt
        )
    }

    /// Parse and validate a decrypted kind-24136 rumor.
    public init(rumor: NostrEvent) throws {
        guard rumor.kind == NostrEventKind.authResponse.rawValue else {
            throw AuthError.kindMismatch(expected: NostrEventKind.authResponse.rawValue, got: rumor.kind)
        }
        let decoded: AuthResponse = try AuthContentCodec.decode(rumor.content)
        guard decoded.type == Self.wireType else {
            throw AuthError.typeMismatch(decoded.type)
        }
        guard decoded.v == 1 else {
            throw AuthError.unsupportedVersion(decoded.v)
        }
        self = decoded
    }
}

// MARK: - Content Codec

/// Encode/decode rumor content JSON. Explicit CodingKeys carry the snake_case
/// contract; sorted keys keep output deterministic, and slashes stay
/// unescaped so `reply_relay` URLs read verbatim.
enum AuthContentCodec {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AuthError.malformedContent
        }
        return json
    }

    static func decode<T: Decodable>(_ content: String) throws -> T {
        guard let data = content.data(using: .utf8) else {
            throw AuthError.malformedContent
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AuthError.malformedContent
        }
    }
}
