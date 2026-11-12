import DPYCAuthKit
import Foundation
import PricingStudioCore

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
    /// The Secure Courier sends every message twice for compatibility: as a
    /// NIP-17 gift wrap and as a NIP-04 copy. Two messages with the same text
    /// and direction are one; the NIP-44 copy wins, else the first arrival.
    /// A courier request's NIP-04 copy is dropped when its form is here: the
    /// form is the one to show (see `isCopy(_:of:)`).
    var dedupedMessages: [DecryptedDM] {
        var seen: [String: DecryptedDM] = [:]
        for dm in messages.sorted(by: { $0.createdAt < $1.createdAt }) {
            let key = "\(dm.isFromMe):\(dm.content)"
            if let existing = seen[key] {
                if Self.prefers(dm, over: existing) { seen[key] = dm }
            } else {
                seen[key] = dm
            }
        }
        let formNonces = Set(seen.values.compactMap(\.courierFormNonce))
        return seen.values
            .filter { dm in dm.courierTextTwinNonce.map { !formNonces.contains($0) } ?? true }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Whether *a* and *b* are two copies of one message: the same text from
    /// the same sender within two days, or a courier request's form and its
    /// text copy (the same nonce, from the same sender).
    static func isCopy(_ a: DecryptedDM, of b: DecryptedDM) -> Bool {
        guard a.senderPubkeyHex == b.senderPubkeyHex else { return false }
        if a.content == b.content {
            return abs(a.createdAt.timeIntervalSince(b.createdAt)) < 48 * 60 * 60
        }
        if let nonce = a.courierFormNonce { return b.courierTextTwinNonce == nonce }
        if let nonce = b.courierFormNonce { return a.courierTextTwinNonce == nonce }
        return false
    }

    /// Which of two copies to keep: a courier form beats its text copy, then
    /// NIP-44 beats NIP-04. *incoming* replaces *existing* only when it wins.
    static func prefers(_ incoming: DecryptedDM, over existing: DecryptedDM) -> Bool {
        let incomingForm = incoming.courierFormNonce != nil
        let existingForm = existing.courierFormNonce != nil
        if incomingForm != existingForm { return incomingForm }
        return incoming.encryption == .nip44 && existing.encryption == .nip04
    }

    /// Merge one live message in. A message already here is ignored; a relay
    /// echo of an optimistic send in *pendingIds* replaces that send; the
    /// other copy of one already here leaves the better of the two (a courier
    /// form replaces its text copy); anything else is appended.
    ///
    /// Returns whether *dm* was appended as new, and the id of the optimistic
    /// send it replaced, if any.
    @discardableResult
    mutating func absorb(
        _ dm: DecryptedDM, pendingIds: Set<String> = []
    ) -> (appended: Bool, replacedPendingId: String?) {
        if messages.contains(where: { $0.rawEventId == dm.rawEventId }) { return (false, nil) }
        if dm.isFromMe, let optIdx = messages.firstIndex(where: {
            $0.isFromMe && $0.content == dm.content
                && abs($0.createdAt.timeIntervalSince(dm.createdAt)) < 120
                && pendingIds.contains($0.rawEventId)
        }) {
            let replaced = messages[optIdx].rawEventId
            messages[optIdx] = dm
            return (false, replaced)
        }
        if let dupIdx = messages.firstIndex(where: { Self.isCopy($0, of: dm) }) {
            if Self.prefers(dm, over: messages[dupIdx]) { messages[dupIdx] = dm }
            return (false, nil)
        }
        messages.append(dm)
        return (true, nil)
    }

    /// Most recent message in the conversation (after deduplication).
    var latestMessage: DecryptedDM? {
        dedupedMessages.last
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

extension DecryptedDM {
    /// The nonce of the courier form this incoming message carries, if any.
    var courierFormNonce: String? {
        isFromMe ? nil : CourierPayload.formNonce(tags: tags)
    }

    /// The nonce of the courier request this incoming message is the text
    /// copy of, if any.
    var courierTextTwinNonce: String? {
        isFromMe ? nil : CourierPayload.textTwinNonce(content: content, tags: tags)
    }
}
