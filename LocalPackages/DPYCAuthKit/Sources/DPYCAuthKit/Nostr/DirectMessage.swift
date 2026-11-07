import Foundation
import OSLog

private let logger = Logger(subsystem: "com.tollbooth.dpyc.DPYCAuthKit", category: "NostrDM")

// MARK: - Decrypted DM Model

public struct DecryptedDM: Identifiable, Sendable {
    public let rawEventId: String
    public let senderPubkeyHex: String
    public let recipientPubkeyHex: String
    public let content: String
    public let createdAt: Date
    public let encryption: EncryptionType
    public let isFromMe: Bool
    /// The message's own tags: the kind 14 rumor's tags for a NIP-17 DM
    /// (private, encrypted with the content), or the kind 4 event's tags.
    public let tags: [[String]]
    /// The message's NIP-01 id: the rumor's for a NIP-17 DM, the event's for
    /// NIP-04. A reply names it in an `e` tag.
    public let messageId: String

    public var id: String { rawEventId }

    public enum EncryptionType: String, Sendable {
        case nip04
        case nip44
    }

    public init(
        rawEventId: String,
        senderPubkeyHex: String,
        recipientPubkeyHex: String,
        content: String,
        createdAt: Date,
        encryption: EncryptionType,
        isFromMe: Bool,
        tags: [[String]] = [],
        messageId: String? = nil
    ) {
        self.rawEventId = rawEventId
        self.senderPubkeyHex = senderPubkeyHex
        self.recipientPubkeyHex = recipientPubkeyHex
        self.content = content
        self.createdAt = createdAt
        self.encryption = encryption
        self.isFromMe = isFromMe
        self.tags = tags
        self.messageId = messageId ?? rawEventId
    }
}

// MARK: - NIP-04 DM Build / Decrypt

public enum NIP04DM {

    /// Build a NIP-04 kind 4 encrypted DM.
    public static func build(
        message: String,
        senderPrivKeyHex: String,
        senderPubKeyHex: String,
        recipientPubKeyHex: String
    ) throws -> NostrEvent {
        let encrypted = try NIP04Service.encrypt(
            message,
            privateKeyHex: senderPrivKeyHex,
            publicKeyHex: recipientPubKeyHex
        )
        return try NostrEvent.signed(
            kind: .encryptedDM,
            content: encrypted,
            tags: [["p", recipientPubKeyHex]],
            privateKeyHex: senderPrivKeyHex,
            publicKeyHex: senderPubKeyHex
        )
    }

    /// Decrypt a NIP-04 kind 4 event.
    public static func decrypt(
        _ event: NostrEvent,
        privateKeyHex: String,
        publicKeyHex: String
    ) -> DecryptedDM? {
        // Determine if we sent or received this DM
        let isFromMe = event.pubkey == publicKeyHex
        let counterpartyHex = isFromMe
            ? (event.tags.first(where: { $0.first == "p" })?[safe: 1] ?? "")
            : event.pubkey

        guard !counterpartyHex.isEmpty else { return nil }

        do {
            let plaintext = try NIP04Service.decrypt(
                event.content,
                privateKeyHex: privateKeyHex,
                publicKeyHex: counterpartyHex
            )
            return DecryptedDM(
                rawEventId: event.id,
                senderPubkeyHex: event.pubkey,
                recipientPubkeyHex: isFromMe ? counterpartyHex : publicKeyHex,
                content: plaintext,
                createdAt: Date(timeIntervalSince1970: TimeInterval(event.created_at)),
                encryption: .nip04,
                isFromMe: isFromMe,
                tags: event.tags
            )
        } catch {
            logger.debug("NIP-04 decrypt failed for \(event.id.prefix(8)): \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Gift-Wrapped DM Adapter

public extension GiftWrap {

    /// Unwrap a NIP-17 gift wrap (kind 1059 → 13 → 14) into a DM.
    static func unwrapDM(
        _ event: NostrEvent,
        privateKeyHex: String,
        publicKeyHex: String
    ) -> DecryptedDM? {
        do {
            let unwrapped = try unwrap(event, recipientPrivateKeyHex: privateKeyHex)
            let rumor = unwrapped.rumor
            guard rumor.kind == NostrEventKind.privateDM.rawValue else {
                logger.debug("Gift wrap \(event.id.prefix(8)) rumor is kind \(rumor.kind), not a DM")
                return nil
            }

            let isFromMe = rumor.pubkey == publicKeyHex
            let recipientHex = rumor.tags
                .first(where: { $0.first == "p" })?[safe: 1] ?? publicKeyHex

            // The rumor's id is recomputed from its fields, never taken from
            // the sender: a reply quotes it to name the request it answers.
            let rumorId = (try? computeEventId(
                pubkey: rumor.pubkey, createdAt: rumor.created_at, kind: rumor.kind,
                tags: rumor.tags, content: rumor.content
            )) ?? event.id

            // The rumor's created_at is the real send time; the gift wrap's
            // timestamp is fuzzed (NIP-17 randomizes it for privacy, often
            // +/- hours from actual send time). unwrap() already prefers it.
            return DecryptedDM(
                rawEventId: event.id,
                senderPubkeyHex: rumor.pubkey,
                recipientPubkeyHex: recipientHex,
                content: rumor.content,
                createdAt: Date(timeIntervalSince1970: TimeInterval(rumor.created_at)),
                encryption: .nip44,
                isFromMe: isFromMe,
                tags: rumor.tags,
                messageId: rumorId
            )
        } catch {
            logger.debug("Gift wrap unwrap failed for \(event.id.prefix(8)): \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Inbound DM Dispatcher

public enum NostrDM {

    /// Try to decrypt a single event (kind 4 or kind 1059), nil on failure.
    public static func decrypt(
        event: NostrEvent,
        privateKeyHex: String,
        publicKeyHex: String
    ) -> DecryptedDM? {
        switch event.kind {
        case NostrEventKind.encryptedDM.rawValue:
            return NIP04DM.decrypt(event, privateKeyHex: privateKeyHex, publicKeyHex: publicKeyHex)
        case NostrEventKind.giftWrap.rawValue:
            return GiftWrap.unwrapDM(event, privateKeyHex: privateKeyHex, publicKeyHex: publicKeyHex)
        default:
            return nil
        }
    }
}
