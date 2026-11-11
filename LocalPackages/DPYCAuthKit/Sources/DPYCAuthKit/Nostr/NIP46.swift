import Foundation

// MARK: - NIP-46 remote signing (Nostr Connect)
//
// Pure codec for the signer side of NIP-46: parse a client's
// `nostrconnect://` token, decrypt its kind-24133 requests, sign what it asks,
// and build the encrypted kind-24133 replies. No sockets and no Keychain here;
// the caller supplies keys and moves events.

/// A client's `nostrconnect://<client-pubkey>?relay=…&secret=…` token.
public struct NostrConnectURI: Equatable, Sendable {
    public let clientPubkey: String
    public let relays: [URL]
    public let secret: String
    public let name: String?
    public let url: String?
    public let image: String?
    public let perms: [String]

    /// Most relays a token may name. A login needs one or two; more is noise
    /// that would open a socket per entry.
    public static let maxRelays = 3

    public enum ParseError: LocalizedError, Equatable {
        case notNostrConnect
        case badClientKey
        case noRelay
        case noSecret

        public var errorDescription: String? {
            switch self {
            case .notNostrConnect: return "That is not a nostrconnect:// link."
            case .badClientKey: return "The link's app key is not a valid Nostr public key."
            case .noRelay: return "The link names no wss:// relay."
            case .noSecret: return "The link carries no secret."
            }
        }
    }

    public static func parse(_ text: String) throws -> NostrConnectURI {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed),
              comps.scheme?.lowercased() == "nostrconnect" else {
            throw ParseError.notNostrConnect
        }
        let key = (comps.host ?? "").lowercased()
        guard key.count == 64, key.allSatisfy({ $0.isHexDigit }) else {
            throw ParseError.badClientKey
        }
        let items = comps.queryItems ?? []
        func value(_ name: String) -> String? {
            let v = items.first { $0.name == name }?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (v?.isEmpty ?? true) ? nil : v
        }

        var relays: [URL] = []
        for item in items where item.name == "relay" {
            guard let raw = item.value, let url = URL(string: raw),
                  url.scheme?.lowercased() == "wss", url.host != nil,
                  !relays.contains(url) else { continue }
            relays.append(url)
            if relays.count == maxRelays { break }
        }
        guard !relays.isEmpty else { throw ParseError.noRelay }
        guard let secret = value("secret") else { throw ParseError.noSecret }

        let perms = (value("perms") ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return NostrConnectURI(
            clientPubkey: key, relays: relays, secret: secret,
            name: value("name"), url: value("url"), image: value("image"), perms: perms
        )
    }
}

/// A signer's `bunker://<signer-pubkey>?relay=…&secret=…` link, which the
/// user pastes into a site; the site then sends `connect` with the secret.
public enum BunkerURI {
    private static let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    public static func make(signerPubkey: String, relays: [URL], secret: String) -> String {
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }
        let query = relays.map { "relay=\(enc($0.absoluteString))" } + ["secret=\(enc(secret))"]
        return "bunker://\(signerPubkey)?\(query.joined(separator: "&"))"
    }
}

/// One decrypted request from the client.
public struct NIP46Request: Codable, Equatable, Sendable {
    public let id: String
    public let method: String
    public let params: [String]

    public init(id: String, method: String, params: [String]) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// The reply to one request. `error` is set only on refusal.
public struct NIP46Response: Codable, Equatable, Sendable {
    public let id: String
    public let result: String
    public let error: String?

    public init(id: String, result: String, error: String? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }
}

/// The event a client asks the signer to sign (`sign_event`'s one param).
public struct NIP46UnsignedEvent: Codable, Equatable, Sendable {
    public let kind: Int
    public let content: String
    public let tags: [[String]]
    public let created_at: Int?

    public init(kind: Int, content: String, tags: [[String]], created_at: Int?) {
        self.kind = kind
        self.content = content
        self.tags = tags
        self.created_at = created_at
    }
}

public enum NIP46 {

    /// How a request's content was encrypted; the reply uses the same.
    public enum Cipher: Sendable, Equatable {
        case nip44
        case nip04

        /// NIP-04 payloads carry `?iv=`; NIP-44 payloads are bare base64.
        public static func of(_ content: String) -> Cipher {
            content.contains("?iv=") ? .nip04 : .nip44
        }
    }

    public enum CodecError: LocalizedError {
        case badSignature
        case wrongKind
        case undecodable

        public var errorDescription: String? {
            switch self {
            case .badSignature: return "The request's signature does not verify."
            case .wrongKind: return "The event is not a NIP-46 message."
            case .undecodable: return "The request could not be read."
            }
        }
    }

    /// Verify and decrypt a kind-24133 request sent to the signer.
    public static func decryptRequest(
        _ event: NostrEvent, signerPrivateKeyHex: String
    ) throws -> (request: NIP46Request, cipher: Cipher) {
        guard event.kind == NostrEventKind.nostrConnect.rawValue else { throw CodecError.wrongKind }
        guard verifyEventSignature(event) else { throw CodecError.badSignature }
        let cipher = Cipher.of(event.content)
        let plaintext = try decrypt(
            event.content, cipher: cipher,
            privateKeyHex: signerPrivateKeyHex, peerPublicKeyHex: event.pubkey
        )
        guard let request = try? JSONDecoder().decode(NIP46Request.self, from: Data(plaintext.utf8)) else {
            throw CodecError.undecodable
        }
        return (request, cipher)
    }

    /// The signed kind-24133 event carrying `response` to `clientPubkey`.
    public static func responseEvent(
        _ response: NIP46Response, to clientPubkey: String, cipher: Cipher,
        signerPrivateKeyHex: String, signerPublicKeyHex: String
    ) throws -> NostrEvent {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(response), as: UTF8.self)
        let content = try encrypt(
            json, cipher: cipher,
            privateKeyHex: signerPrivateKeyHex, peerPublicKeyHex: clientPubkey
        )
        return try NostrEvent.signed(
            kind: .nostrConnect, content: content, tags: [["p", clientPubkey]],
            privateKeyHex: signerPrivateKeyHex, publicKeyHex: signerPublicKeyHex
        )
    }

    /// Whether `request` is a `connect` to `signerPubkey` carrying `secret`
    /// (params: `[signer-pubkey, secret, perms?]`). NDK — Stacker News's
    /// client — leaves the first param empty when the link has no `pubkey=`,
    /// so empty is accepted; the secret is what proves the paste. Compares
    /// the secret in constant time.
    public static func isConnect(_ request: NIP46Request, to signerPubkey: String, secret: String) -> Bool {
        guard request.method == "connect", request.params.count >= 2 else { return false }
        let named = request.params[0].lowercased()
        guard named.isEmpty || named == signerPubkey.lowercased() else { return false }
        let given = Array(request.params[1].utf8), expected = Array(secret.utf8)
        guard given.count == expected.count, !expected.isEmpty else { return false }
        return zip(given, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Decode `sign_event`'s param.
    public static func unsignedEvent(from param: String) throws -> NIP46UnsignedEvent {
        guard let event = try? JSONDecoder().decode(NIP46UnsignedEvent.self, from: Data(param.utf8)) else {
            throw CodecError.undecodable
        }
        return event
    }

    /// Sign `unsigned` as the signer; returns the signed event as JSON — the
    /// `sign_event` result.
    public static func sign(
        _ unsigned: NIP46UnsignedEvent, privateKeyHex: String, publicKeyHex: String
    ) throws -> String {
        let event = try NostrEvent.signed(
            kindNumber: unsigned.kind, content: unsigned.content, tags: unsigned.tags,
            privateKeyHex: privateKeyHex, publicKeyHex: publicKeyHex,
            createdAt: unsigned.created_at
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(event), as: UTF8.self)
    }

    // MARK: - Ciphers

    public static func encrypt(
        _ plaintext: String, cipher: Cipher, privateKeyHex: String, peerPublicKeyHex: String
    ) throws -> String {
        switch cipher {
        case .nip44:
            return try NIP44Service.encrypt(plaintext, privateKeyHex: privateKeyHex, publicKeyHex: peerPublicKeyHex)
        case .nip04:
            return try NIP04Service.encrypt(plaintext, privateKeyHex: privateKeyHex, publicKeyHex: peerPublicKeyHex)
        }
    }

    public static func decrypt(
        _ payload: String, cipher: Cipher, privateKeyHex: String, peerPublicKeyHex: String
    ) throws -> String {
        switch cipher {
        case .nip44:
            return try NIP44Service.decrypt(payload, privateKeyHex: privateKeyHex, publicKeyHex: peerPublicKeyHex)
        case .nip04:
            return try NIP04Service.decrypt(payload, privateKeyHex: privateKeyHex, publicKeyHex: peerPublicKeyHex)
        }
    }
}
