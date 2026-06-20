import CryptoKit
import Foundation
import P256K
import Security

// MARK: - Nostr Event Kinds

enum NostrEventKind: Int, Codable, Sendable {
    case metadata = 0          // NIP-01 kind-0 profile metadata
    case encryptedDM = 4      // NIP-04 legacy DMs
    case deletion = 5          // NIP-09 event deletion
    case seal = 13             // NIP-59 seal (middle layer)
    case privateDM = 14        // NIP-17 private DM (inner layer)
    case giftWrap = 1059       // NIP-17 gift wrap (outer layer)
    case httpAuth = 27235      // NIP-98 HTTP Auth (operator proof)
}

// MARK: - Nostr Event

struct NostrEvent: Codable, Sendable, Identifiable {
    let id: String
    let pubkey: String
    let created_at: Int
    let kind: Int
    let tags: [[String]]
    let content: String
    let sig: String

    var eventKind: NostrEventKind? { NostrEventKind(rawValue: kind) }

    /// Build a signed Nostr event.
    static func signed(
        kind: NostrEventKind,
        content: String,
        tags: [[String]],
        privateKeyHex: String,
        publicKeyHex: String,
        createdAt: Int? = nil
    ) throws -> NostrEvent {
        let timestamp = createdAt ?? Int(Date().timeIntervalSince1970)
        let eventId = try computeEventId(
            pubkey: publicKeyHex,
            createdAt: timestamp,
            kind: kind.rawValue,
            tags: tags,
            content: content
        )
        let sig = try signEventId(eventId, privateKeyHex: privateKeyHex)
        return NostrEvent(
            id: eventId,
            pubkey: publicKeyHex,
            created_at: timestamp,
            kind: kind.rawValue,
            tags: tags,
            content: content,
            sig: sig
        )
    }

    /// Build an unsigned rumor (for NIP-17 innermost layer).
    static func rumor(
        kind: NostrEventKind,
        content: String,
        tags: [[String]],
        publicKeyHex: String,
        createdAt: Int? = nil
    ) throws -> NostrEvent {
        let timestamp = createdAt ?? Int(Date().timeIntervalSince1970)
        let eventId = try computeEventId(
            pubkey: publicKeyHex,
            createdAt: timestamp,
            kind: kind.rawValue,
            tags: tags,
            content: content
        )
        return NostrEvent(
            id: eventId,
            pubkey: publicKeyHex,
            created_at: timestamp,
            kind: kind.rawValue,
            tags: tags,
            content: content,
            sig: ""
        )
    }

    /// Serialize to Nostr relay publish message: `["EVENT", {...}]`
    func toRelayMessage() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let eventData = try encoder.encode(self)
        guard let eventJSON = String(data: eventData, encoding: .utf8) else {
            throw NostrEventError.serializationFailed
        }
        return "[\"EVENT\",\(eventJSON)]"
    }
}

// MARK: - Event ID Computation

/// Compute Nostr event ID: SHA-256 of `[0, pubkey, created_at, kind, tags, content]`.
func computeEventId(
    pubkey: String,
    createdAt: Int,
    kind: Int,
    tags: [[String]],
    content: String
) throws -> String {
    let serialized: [Any] = [0, pubkey, createdAt, kind, tags, content]
    let jsonData = try JSONSerialization.data(
        withJSONObject: serialized,
        options: [.withoutEscapingSlashes, .sortedKeys]
    )
    let hash = CryptoKit.SHA256.hash(data: jsonData)
    return hash.compactMap { String(format: "%02x", $0) }.joined()
}

// MARK: - Schnorr Signing

/// Sign an event ID (hex) with a Schnorr private key.
///
/// Uses the raw message signing API to avoid double-hashing — the event ID
/// is already a SHA-256 hash.
func signEventId(_ eventIdHex: String, privateKeyHex: String) throws -> String {
    guard let privKeyData = Data(hexString: privateKeyHex), privKeyData.count == 32 else {
        throw NostrEventError.invalidPrivateKey
    }
    guard let eventIdData = Data(hexString: eventIdHex), eventIdData.count == 32 else {
        throw NostrEventError.invalidEventId
    }

    let privKey = try P256K.Schnorr.PrivateKey(dataRepresentation: Array(privKeyData))
    var messageBytes = Array(eventIdData)
    var auxRand = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, 32, &auxRand)
    let signature = try privKey.signature(message: &messageBytes, auxiliaryRand: &auxRand)
    return signature.dataRepresentation.hexString
}

// MARK: - Timestamp Helpers

/// NIP-17 fuzzed timestamp: 0–48 hours into the past.
func randomizedTimestamp() -> Int {
    let fuzzWindow = 2 * 24 * 60 * 60  // 48 hours
    return Int(Date().timeIntervalSince1970) - Int.random(in: 0...fuzzWindow)
}

// MARK: - Errors

enum NostrEventError: LocalizedError {
    case invalidPrivateKey
    case invalidEventId
    case serializationFailed

    var errorDescription: String? {
        switch self {
        case .invalidPrivateKey: return "Invalid 32-byte private key"
        case .invalidEventId: return "Invalid 32-byte event ID"
        case .serializationFailed: return "Failed to serialize event"
        }
    }
}

// MARK: - Data Hex Extensions

extension Data {
    init?(hexString: String) {
        let hex = hexString.dropFirst(hexString.hasPrefix("0x") ? 2 : 0)
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - kind-0 Profile (NIP-01)

/// NIP-01 kind-0 profile metadata. `picture`/`banner` are public URLs
/// (Iconify SVGs, hosted images) — never bitmap bytes. nil optionals are
/// omitted from the JSON (synthesized `encodeIfPresent`).
struct NostrProfileMetadata: Codable, Sendable, Equatable {
    var name: String? = nil
    var display_name: String? = nil
    var about: String? = nil
    var picture: String? = nil
    var nip05: String? = nil
    var website: String? = nil
    var lud16: String? = nil
    var banner: String? = nil

    /// Trim whitespace and drop empty strings so blank fields don't publish.
    func normalized() -> NostrProfileMetadata {
        func clean(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t?.isEmpty ?? true) ? nil : t
        }
        return NostrProfileMetadata(
            name: clean(name), display_name: clean(display_name), about: clean(about),
            picture: clean(picture), nip05: clean(nip05), website: clean(website),
            lud16: clean(lud16), banner: clean(banner)
        )
    }
}

enum NostrProfileError: LocalizedError {
    case noSigningKey

    var errorDescription: String? {
        switch self {
        case .noSigningKey:
            return "No signing key (nsec) is held for this identity. Profiles are signed by your own key — add the nsec first."
        }
    }
}

/// Read and publish a holder's own Nostr kind-0 profile. Studio signs with the
/// identity's Keychain nsec and publishes straight to relays — self-sovereign,
/// no nsec ever leaves the device, no operator/MCP intermediary. `picture` is a
/// public URL (no image upload).
struct NostrProfileService {
    let relayService: NostrRelayService

    init(relayService: NostrRelayService = NostrRelayService()) {
        self.relayService = relayService
    }

    /// Read the latest kind-0 for `npub` from relays. nil if none / unreachable.
    func fetch(npub: String) async -> NostrProfileMetadata? {
        guard let hex = try? NostrKeyService.publicKeyHexFromNpub(npub) else { return nil }
        guard let event = await relayService.fetchProfileEvent(pubkeyHex: hex),
              let data = event.content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(NostrProfileMetadata.self, from: data)
    }

    /// Sign a kind-0 with `npub`'s Keychain nsec and publish to relays.
    func publish(npub: String, metadata: NostrProfileMetadata) async throws -> [(URL, Bool, String)] {
        guard let nsec = KeychainService.loadNsec(forNpub: npub) else {
            throw NostrProfileError.noSigningKey
        }
        let privHex = try NostrKeyService.privateKeyHexFromNsec(nsec)
        let pubHex = try NostrKeyService.publicKeyHexFromNpub(npub)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let content = String(
            data: try encoder.encode(metadata.normalized()), encoding: .utf8
        ) ?? "{}"

        let event = try NostrEvent.signed(
            kind: .metadata, content: content, tags: [],
            privateKeyHex: privHex, publicKeyHex: pubHex
        )
        return await relayService.publish(event)
    }
}
