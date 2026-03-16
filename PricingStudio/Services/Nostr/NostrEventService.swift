import CryptoKit
import Foundation
import P256K
import Security

// MARK: - Nostr Event Kinds

enum NostrEventKind: Int, Codable, Sendable {
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
