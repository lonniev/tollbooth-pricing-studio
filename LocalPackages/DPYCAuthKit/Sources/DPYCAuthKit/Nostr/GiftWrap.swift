import Foundation
import OSLog
import P256K

private let logger = Logger(subsystem: "com.tollbooth.dpyc.DPYCAuthKit", category: "GiftWrap")

/// A rumor recovered from a NIP-59 gift wrap, together with the pubkey that
/// signed the seal. The seal signature is the proof of authorship — callers
/// making trust decisions MUST check `sealPubkey`, never the rumor alone.
public struct UnwrappedRumor: Sendable {
    public let rumor: NostrEvent
    public let sealPubkey: String
}

/// NIP-59 gift wrap: rumor → kind-13 seal (signed by real sender, NIP-44
/// encrypted) → kind-1059 wrap (signed by a single-use ephemeral key).
public enum GiftWrap {

    /// Wrap a pre-built rumor (any kind: 14 DM, 24135/24136 wrist approval).
    public static func wrap(
        rumor: NostrEvent,
        senderPrivKeyHex: String,
        senderPubKeyHex: String,
        recipientPubKeyHex: String
    ) throws -> NostrEvent {
        let rumorJSON = try jsonEncode(rumor)

        // Kind 13 seal — NIP-44 encrypt rumor, sign with sender
        let sealContent = try NIP44Service.encrypt(
            rumorJSON,
            privateKeyHex: senderPrivKeyHex,
            publicKeyHex: recipientPubKeyHex
        )
        let seal = try NostrEvent.signed(
            kind: .seal,
            content: sealContent,
            tags: [],  // No tags for metadata protection
            privateKeyHex: senderPrivKeyHex,
            publicKeyHex: senderPubKeyHex,
            createdAt: randomizedTimestamp()
        )
        let sealJSON = try jsonEncode(seal)

        // Kind 1059 gift wrap — random ephemeral key
        let ephemeralPrivBytes = generateRandomBytes(32)
        let ephemeralPrivKey = try P256K.Schnorr.PrivateKey(dataRepresentation: ephemeralPrivBytes)
        let ephemeralPrivHex = Data(ephemeralPrivBytes).hexString
        let ephemeralPubHex = Data(ephemeralPrivKey.xonly.bytes).hexString

        let wrapContent = try NIP44Service.encrypt(
            sealJSON,
            privateKeyHex: ephemeralPrivHex,
            publicKeyHex: recipientPubKeyHex
        )
        return try NostrEvent.signed(
            kind: .giftWrap,
            content: wrapContent,
            tags: [["p", recipientPubKeyHex]],  // p-tag for relay routing
            privateKeyHex: ephemeralPrivHex,
            publicKeyHex: ephemeralPubHex,
            createdAt: randomizedTimestamp()
        )
    }

    /// Build a NIP-17 gift-wrapped DM: kind 14 rumor → kind 13 → kind 1059.
    public static func wrapDM(
        message: String,
        senderPrivKeyHex: String,
        senderPubKeyHex: String,
        recipientPubKeyHex: String
    ) throws -> NostrEvent {
        let rumor = try NostrEvent.rumor(
            kind: .privateDM,
            content: message,
            tags: [["p", recipientPubKeyHex]],
            publicKeyHex: senderPubKeyHex
        )
        return try wrap(
            rumor: rumor,
            senderPrivKeyHex: senderPrivKeyHex,
            senderPubKeyHex: senderPubKeyHex,
            recipientPubKeyHex: recipientPubKeyHex
        )
    }

    /// Unwrap a kind-1059 gift wrap to its rumor, kind-agnostic.
    ///
    /// Validates the wrap and seal kinds and that the rumor's claimed author
    /// matches the seal signer — a rumor claiming a different pubkey than the
    /// key that sealed it is an impersonation attempt, not a valid message.
    /// A rumor with no pubkey field inherits the seal pubkey.
    public static func unwrap(
        _ event: NostrEvent,
        recipientPrivateKeyHex: String
    ) throws -> UnwrappedRumor {
        guard event.kind == NostrEventKind.giftWrap.rawValue else {
            throw GiftWrapError.invalidWrapKind(event.kind)
        }

        // Layer 1: decrypt wrap content with our privkey + ephemeral wrap pubkey
        let sealJSON = try NIP44Service.decrypt(
            event.content,
            privateKeyHex: recipientPrivateKeyHex,
            publicKeyHex: event.pubkey
        )

        // Layer 2: parse + validate seal
        guard let sealData = sealJSON.data(using: .utf8),
              let sealDict = try JSONSerialization.jsonObject(with: sealData) as? [String: Any],
              let sealKind = sealDict["kind"] as? Int,
              sealKind == NostrEventKind.seal.rawValue,
              let sealPubkey = sealDict["pubkey"] as? String,
              let sealContent = sealDict["content"] as? String else {
            throw GiftWrapError.invalidSeal
        }

        // Layer 3: decrypt seal content with our privkey + sender's pubkey
        let rumorJSON = try NIP44Service.decrypt(
            sealContent,
            privateKeyHex: recipientPrivateKeyHex,
            publicKeyHex: sealPubkey
        )

        guard let rumorData = rumorJSON.data(using: .utf8),
              let rumorDict = try JSONSerialization.jsonObject(with: rumorData) as? [String: Any],
              let rumorKind = rumorDict["kind"] as? Int,
              let rumorContent = rumorDict["content"] as? String else {
            throw GiftWrapError.invalidRumor
        }

        let rumorPubkey = rumorDict["pubkey"] as? String ?? sealPubkey
        guard rumorPubkey == sealPubkey else {
            throw GiftWrapError.rumorSealAuthorMismatch
        }

        let rumor = NostrEvent(
            id: rumorDict["id"] as? String ?? "",
            pubkey: rumorPubkey,
            created_at: rumorDict["created_at"] as? Int ?? event.created_at,
            kind: rumorKind,
            tags: rumorDict["tags"] as? [[String]] ?? [],
            content: rumorContent,
            sig: ""
        )
        return UnwrappedRumor(rumor: rumor, sealPubkey: sealPubkey)
    }

    // MARK: - Helpers

    static func jsonEncode(_ event: NostrEvent) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(event)
        guard let str = String(data: data, encoding: .utf8) else {
            throw GiftWrapError.serializationFailed
        }
        return str
    }

    static func generateRandomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes
    }
}

// MARK: - Errors

public enum GiftWrapError: LocalizedError, Equatable {
    case invalidWrapKind(Int)
    case invalidSeal
    case invalidRumor
    case rumorSealAuthorMismatch
    case serializationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidWrapKind(let kind):
            return "Expected kind 1059 gift wrap, got kind \(kind)"
        case .invalidSeal:
            return "Gift wrap does not contain a valid kind-13 seal"
        case .invalidRumor:
            return "Seal does not contain a valid rumor"
        case .rumorSealAuthorMismatch:
            return "Rumor author does not match the seal signer"
        case .serializationFailed:
            return "Event serialization failed"
        }
    }
}

// MARK: - Safe Array Index

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
