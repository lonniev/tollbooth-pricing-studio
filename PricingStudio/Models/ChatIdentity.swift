import Foundation

/// Represents any entity that can participate in Nostr DM conversations.
///
/// Resolves the nsec from Keychain by npub, providing hex keys for crypto operations.
struct ChatIdentity: Sendable {
    let npub: String
    let displayName: String
    let entityType: EntityType

    enum EntityType: String, Sendable {
        case authority
        case `operator`
        case patron
    }

    /// Whether this entity has an nsec stored in Keychain.
    var hasNsec: Bool {
        KeychainService.loadNsec(forNpub: npub) != nil
    }

    /// The 32-byte private key as hex, or nil if no nsec is stored.
    var privateKeyHex: String? {
        guard let nsec = KeychainService.loadNsec(forNpub: npub) else { return nil }
        return try? NostrKeyService.privateKeyHexFromNsec(nsec)
    }

    /// The 32-byte public key as hex.
    var publicKeyHex: String {
        (try? NostrKeyService.publicKeyHexFromNpub(npub)) ?? ""
    }
}

// MARK: - Convenience Initializers

extension ChatIdentity {
    init(from authority: Authority) {
        self.npub = authority.npub
        self.displayName = authority.displayName
        self.entityType = .authority
    }

    init(from operator_: Operator) {
        self.npub = operator_.npub
        self.displayName = operator_.displayName
        self.entityType = .operator
    }

    init(from patron: Patron) {
        self.npub = patron.npub
        self.displayName = patron.displayName
        self.entityType = .patron
    }
}
