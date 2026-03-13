import Foundation

/// A conversation with a single counterparty, containing all decrypted DMs.
struct DMConversation: Identifiable, Sendable {
    let counterpartyPubkeyHex: String
    var counterpartyNpub: String? {
        try? NostrKeyService.npubFromHex(counterpartyPubkeyHex)
    }
    var messages: [DecryptedDM]

    var id: String { counterpartyPubkeyHex }

    /// Most recent message in the conversation.
    var latestMessage: DecryptedDM? {
        messages.last
    }

    /// Display-friendly counterparty identifier.
    var counterpartyDisplayName: String {
        if let npub = counterpartyNpub {
            let prefix = npub.prefix(12)
            let suffix = npub.suffix(4)
            return "\(prefix)...\(suffix)"
        }
        let prefix = counterpartyPubkeyHex.prefix(8)
        return "\(prefix)..."
    }
}
