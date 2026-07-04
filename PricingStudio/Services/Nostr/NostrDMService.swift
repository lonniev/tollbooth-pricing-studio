import DPYCAuthKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.tollbooth.dpyc.PricingStudio", category: "NostrDM")

/// Orchestrates Nostr DM operations: fetch, decrypt, send, delete.
///
/// Crypto (NIP-04, NIP-17 gift wrap) lives in DPYCAuthKit; this actor owns
/// the relay orchestration, courier rendezvous pinning, and traffic logging.
actor NostrDMService {

    private let relay: NostrRelayService

    init(relay: NostrRelayService = NostrRelayService()) {
        self.relay = relay
    }

    // MARK: - Fetch & Decrypt Conversations

    /// Fetch DMs from relays, decrypt all, and group by counterparty.
    func fetchConversations(
        privateKeyHex: String,
        publicKeyHex: String,
        since: Int? = nil
    ) async -> [String: [DecryptedDM]] {
        let (events, _) = await relay.fetchDMs(pubkeyHex: publicKeyHex, since: since)
        var dmsByCounterparty: [String: [DecryptedDM]] = [:]
        var decryptedCount = 0

        for event in events {
            guard let dm = NostrDM.decrypt(
                event: event,
                privateKeyHex: privateKeyHex,
                publicKeyHex: publicKeyHex
            ) else { continue }

            decryptedCount += 1
            let counterparty = dm.isFromMe ? dm.recipientPubkeyHex : dm.senderPubkeyHex
            dmsByCounterparty[counterparty, default: []].append(dm)
        }

        // Sort each conversation by timestamp
        for key in dmsByCounterparty.keys {
            dmsByCounterparty[key]?.sort { $0.createdAt < $1.createdAt }
        }

        let senderNpub = try? NostrKeyService.npubFromHex(publicKeyHex)
        await MainActor.run {
            let parties = dmsByCounterparty.keys.map { String($0.prefix(8)) }.joined(separator: ", ")
            TrafficLogger.shared.log(.inbound, label: "DM Decrypt", detail: "\(decryptedCount)/\(events.count) OK, counterparties: \(parties)", npub: senderNpub)
        }

        return dmsByCounterparty
    }

    // MARK: - Send DM (Dual Protocol)

    /// Send a DM via both NIP-17 gift wrap and NIP-04 legacy.
    ///
    /// When `pinnedRelay` is given (courier rendezvous pinning), the send
    /// only counts as successful if that exact relay accepted the event —
    /// the courier's listener drains only its rendezvous relay, so a reply
    /// that lands anywhere else is invisible to it.
    func sendDM(
        privateKeyHex: String,
        publicKeyHex: String,
        recipientPubkeyHex: String,
        message: String,
        pinnedRelay: URL? = nil
    ) async throws {
        var nip17OK = false
        var nip04OK = false
        var pinnedOK = false
        var errors: [String] = []

        func pinnedAccepted(_ results: [(URL, Bool, String)]) -> Bool {
            guard let pinned = pinnedRelay else { return true }
            return results.contains { $0.0 == pinned && $0.1 }
        }

        // NIP-17 gift wrap (kind 1059 → 13 → 14)
        do {
            let wrapEvent = try GiftWrap.wrapDM(
                message: message,
                senderPrivKeyHex: privateKeyHex,
                senderPubKeyHex: publicKeyHex,
                recipientPubKeyHex: recipientPubkeyHex
            )
            let results = await relay.publish(wrapEvent, primaryRelay: pinnedRelay)
            let accepted = results.filter { $0.1 }.count
            nip17OK = accepted > 0
            pinnedOK = pinnedOK || pinnedAccepted(results)
            if !nip17OK {
                let details = results.filter { !$0.1 }.map { "\($0.0): \($0.2)" }.joined(separator: "; ")
                errors.append("NIP-17: \(details)")
            }
        } catch {
            errors.append("NIP-17: \(error.localizedDescription)")
        }

        // NIP-04 legacy DM (kind 4)
        do {
            let dmEvent = try NIP04DM.build(
                message: message,
                senderPrivKeyHex: privateKeyHex,
                senderPubKeyHex: publicKeyHex,
                recipientPubKeyHex: recipientPubkeyHex
            )
            let results = await relay.publish(dmEvent, primaryRelay: pinnedRelay)
            let accepted = results.filter { $0.1 }.count
            nip04OK = accepted > 0
            pinnedOK = pinnedOK || pinnedAccepted(results)
            if !nip04OK {
                let details = results.filter { !$0.1 }.map { "\($0.0): \($0.2)" }.joined(separator: "; ")
                errors.append("NIP-04: \(details)")
            }
        } catch {
            errors.append("NIP-04: \(error.localizedDescription)")
        }

        let senderNpub = try? NostrKeyService.npubFromHex(publicKeyHex)

        if !nip17OK && !nip04OK {
            await MainActor.run {
                TrafficLogger.shared.log(.error, label: "DM Send Failed", detail: errors.joined(separator: "; "), npub: senderNpub)
            }
            throw DMError.allSendsFailed(errors.joined(separator: "; "))
        }

        if let pinned = pinnedRelay, !pinnedOK {
            let detail = errors.isEmpty ? "relay did not acknowledge the event" : errors.joined(separator: "; ")
            await MainActor.run {
                TrafficLogger.shared.log(.error, label: "DM Pin Missed", detail: "\(pinned.absoluteString): \(detail)", npub: senderNpub)
            }
            throw DMError.pinnedRelayFailed(pinned.absoluteString, detail)
        }

        await MainActor.run {
            let pinNote = pinnedRelay.map { ", pinned \($0.host ?? $0.absoluteString): OK" } ?? ""
            TrafficLogger.shared.log(.outbound, label: "DM Sent", detail: "\(publicKeyHex.prefix(8))\u{2192}\(recipientPubkeyHex.prefix(8)) NIP-17: \(nip17OK ? "OK" : "fail"), NIP-04: \(nip04OK ? "OK" : "fail")\(pinNote)", npub: senderNpub)
        }
        logger.info("Sent DM (NIP-17: \(nip17OK), NIP-04: \(nip04OK))")
    }

    // MARK: - Request Deletion (NIP-09)

    /// Publish NIP-09 deletion requests for the given event IDs.
    func requestDeletion(
        privateKeyHex: String,
        publicKeyHex: String,
        eventIds: [String]
    ) async {
        for eventId in eventIds {
            do {
                let event = try NostrEvent.signed(
                    kind: .deletion,
                    content: "message deleted",
                    tags: [["e", eventId]],
                    privateKeyHex: privateKeyHex,
                    publicKeyHex: publicKeyHex
                )
                _ = await relay.publish(event)
            } catch {
                logger.debug("Failed to create deletion event for \(eventId): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Decrypt Events

    /// Try to decrypt a single event, returning nil on failure.
    func decryptEvent(
        _ event: NostrEvent,
        privateKeyHex: String,
        publicKeyHex: String
    ) -> DecryptedDM? {
        NostrDM.decrypt(event: event, privateKeyHex: privateKeyHex, publicKeyHex: publicKeyHex)
    }
}

// MARK: - DM Errors

enum DMError: LocalizedError {
    case allSendsFailed(String)
    case pinnedRelayFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .allSendsFailed(let detail): return "All relay sends failed: \(detail)"
        case .pinnedRelayFailed(let relay, let detail):
            return "The courier is listening on \(relay), but the reply could not be published there: \(detail). Retry — the reply must land on that exact relay to be seen."
        }
    }
}
