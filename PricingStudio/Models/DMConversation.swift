import Foundation

/// A conversation with a single counterparty, containing all decrypted DMs.
struct DMConversation: Identifiable, Sendable {
    let counterpartyPubkeyHex: String
    var counterpartyNpub: String? {
        try? NostrKeyService.npubFromHex(counterpartyPubkeyHex)
    }
    var messages: [DecryptedDM]

    var id: String { counterpartyPubkeyHex }

    /// Messages with NIP-04/NIP-17 duplicates removed.
    ///
    /// The Secure Courier sends both a NIP-04 and NIP-17 copy for
    /// compatibility. They may arrive at very different times. Dedup by
    /// (content, direction) — if two messages have the same text and the
    /// same direction, keep the one with stronger encryption (NIP-44)
    /// or the earlier arrival if encryption matches.
    var dedupedMessages: [DecryptedDM] {
        var seen: [String: DecryptedDM] = [:]
        for dm in messages.sorted(by: { $0.createdAt < $1.createdAt }) {
            let key = "\(dm.isFromMe):\(dm.content.prefix(200))"
            if let existing = seen[key] {
                // Prefer NIP-44 over NIP-04; otherwise keep the first arrival
                if dm.encryption == .nip44 && existing.encryption == .nip04 {
                    seen[key] = dm
                }
            } else {
                seen[key] = dm
            }
        }
        return seen.values.sorted { $0.createdAt < $1.createdAt }
    }

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
