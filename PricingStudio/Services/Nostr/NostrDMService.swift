import Foundation
import OSLog
import P256K

private let logger = Logger(subsystem: "com.tollbooth.dpyc.PricingStudio", category: "NostrDM")

/// Orchestrates Nostr DM operations: fetch, decrypt, send, delete.
///
/// Handles both NIP-04 (kind 4) and NIP-17 (kind 1059 gift wrap) protocols.
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
        let events = await relay.fetchDMs(pubkeyHex: publicKeyHex, since: since)
        var dmsByCounterparty: [String: [DecryptedDM]] = [:]
        var decryptedCount = 0

        for event in events {
            guard let dm = decryptEvent(
                event,
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

        await MainActor.run {
            let parties = dmsByCounterparty.keys.map { String($0.prefix(8)) }.joined(separator: ", ")
            TrafficLogger.shared.log(.inbound, label: "DM Decrypt", detail: "\(decryptedCount)/\(events.count) OK, counterparties: \(parties)")
        }

        return dmsByCounterparty
    }

    // MARK: - Send DM (Dual Protocol)

    /// Send a DM via both NIP-17 gift wrap and NIP-04 legacy.
    func sendDM(
        privateKeyHex: String,
        publicKeyHex: String,
        recipientPubkeyHex: String,
        message: String
    ) async throws {
        var nip17OK = false
        var nip04OK = false
        var errors: [String] = []

        // NIP-17 gift wrap (kind 1059 → 13 → 14)
        do {
            let wrapEvent = try buildGiftWrap(
                senderPrivKeyHex: privateKeyHex,
                senderPubKeyHex: publicKeyHex,
                recipientPubKeyHex: recipientPubkeyHex,
                message: message
            )
            let results = await relay.publish(wrapEvent)
            let accepted = results.filter { $0.1 }.count
            nip17OK = accepted > 0
            if !nip17OK {
                let details = results.filter { !$0.1 }.map { "\($0.0): \($0.2)" }.joined(separator: "; ")
                errors.append("NIP-17: \(details)")
            }
        } catch {
            errors.append("NIP-17: \(error.localizedDescription)")
        }

        // NIP-04 legacy DM (kind 4)
        do {
            let dmEvent = try buildNIP04DM(
                senderPrivKeyHex: privateKeyHex,
                senderPubKeyHex: publicKeyHex,
                recipientPubKeyHex: recipientPubkeyHex,
                message: message
            )
            let results = await relay.publish(dmEvent)
            let accepted = results.filter { $0.1 }.count
            nip04OK = accepted > 0
            if !nip04OK {
                let details = results.filter { !$0.1 }.map { "\($0.0): \($0.2)" }.joined(separator: "; ")
                errors.append("NIP-04: \(details)")
            }
        } catch {
            errors.append("NIP-04: \(error.localizedDescription)")
        }

        if !nip17OK && !nip04OK {
            await MainActor.run {
                TrafficLogger.shared.log(.error, label: "DM Send Failed", detail: errors.joined(separator: "; "))
            }
            throw DMError.allSendsFailed(errors.joined(separator: "; "))
        }

        await MainActor.run {
            TrafficLogger.shared.log(.outbound, label: "DM Sent", detail: "\(publicKeyHex.prefix(8))\u{2192}\(recipientPubkeyHex.prefix(8)) NIP-17: \(nip17OK ? "OK" : "fail"), NIP-04: \(nip04OK ? "OK" : "fail")")
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

    // MARK: - NIP-17 Gift Wrap (3 layers)

    /// Build a NIP-17 gift-wrapped DM: kind 14 → kind 13 → kind 1059.
    private func buildGiftWrap(
        senderPrivKeyHex: String,
        senderPubKeyHex: String,
        recipientPubKeyHex: String,
        message: String
    ) throws -> NostrEvent {
        // Layer 3: Kind 14 rumor — unsigned private DM
        let rumor = try NostrEvent.rumor(
            kind: .privateDM,
            content: message,
            tags: [["p", recipientPubKeyHex]],
            publicKeyHex: senderPubKeyHex
        )
        let rumorJSON = try jsonEncode(rumor)

        // Layer 2: Kind 13 seal — NIP-44 encrypt rumor, sign with sender
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

        // Layer 1: Kind 1059 gift wrap — random ephemeral key
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

    // MARK: - NIP-04 DM Builder

    /// Build a NIP-04 kind 4 encrypted DM.
    private func buildNIP04DM(
        senderPrivKeyHex: String,
        senderPubKeyHex: String,
        recipientPubKeyHex: String,
        message: String
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

    // MARK: - Decrypt Events

    /// Try to decrypt a single event, returning nil on failure.
    private func decryptEvent(
        _ event: NostrEvent,
        privateKeyHex: String,
        publicKeyHex: String
    ) -> DecryptedDM? {
        switch event.kind {
        case NostrEventKind.encryptedDM.rawValue:
            return decryptNIP04Event(event, privateKeyHex: privateKeyHex, publicKeyHex: publicKeyHex)
        case NostrEventKind.giftWrap.rawValue:
            return unwrapGiftWrap(event, privateKeyHex: privateKeyHex, publicKeyHex: publicKeyHex)
        default:
            return nil
        }
    }

    /// Decrypt a NIP-04 kind 4 event.
    private func decryptNIP04Event(
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
                isFromMe: isFromMe
            )
        } catch {
            logger.debug("NIP-04 decrypt failed for \(event.id.prefix(8)): \(error.localizedDescription)")
            return nil
        }
    }

    /// Unwrap a NIP-17 gift wrap (kind 1059 → 13 → 14).
    private func unwrapGiftWrap(
        _ event: NostrEvent,
        privateKeyHex: String,
        publicKeyHex: String
    ) -> DecryptedDM? {
        do {
            // Layer 1: Decrypt gift wrap content with our privkey + wrap's ephemeral pubkey
            let sealJSON = try NIP44Service.decrypt(
                event.content,
                privateKeyHex: privateKeyHex,
                publicKeyHex: event.pubkey
            )

            // Layer 2: Parse seal
            guard let sealData = sealJSON.data(using: .utf8),
                  let sealDict = try JSONSerialization.jsonObject(with: sealData) as? [String: Any],
                  let sealKind = sealDict["kind"] as? Int,
                  sealKind == NostrEventKind.seal.rawValue,
                  let sealPubkey = sealDict["pubkey"] as? String,
                  let sealContent = sealDict["content"] as? String else {
                logger.debug("Invalid seal in gift wrap \(event.id.prefix(8))")
                return nil
            }

            // Layer 3: Decrypt seal content with our privkey + sender's pubkey
            let dmJSON = try NIP44Service.decrypt(
                sealContent,
                privateKeyHex: privateKeyHex,
                publicKeyHex: sealPubkey
            )

            guard let dmData = dmJSON.data(using: .utf8),
                  let dmDict = try JSONSerialization.jsonObject(with: dmData) as? [String: Any],
                  let dmKind = dmDict["kind"] as? Int,
                  dmKind == NostrEventKind.privateDM.rawValue,
                  let dmContent = dmDict["content"] as? String else {
                logger.debug("Invalid DM in seal \(event.id.prefix(8))")
                return nil
            }

            let dmPubkey = dmDict["pubkey"] as? String ?? sealPubkey
            let isFromMe = dmPubkey == publicKeyHex
            let recipientHex = (dmDict["tags"] as? [[String]])?
                .first(where: { $0.first == "p" })?[safe: 1] ?? publicKeyHex

            return DecryptedDM(
                rawEventId: event.id,
                senderPubkeyHex: dmPubkey,
                recipientPubkeyHex: recipientHex,
                content: dmContent,
                createdAt: Date(timeIntervalSince1970: TimeInterval(event.created_at)),
                encryption: .nip44,
                isFromMe: isFromMe
            )
        } catch {
            logger.debug("Gift wrap unwrap failed for \(event.id.prefix(8)): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Helpers

    private func jsonEncode(_ event: NostrEvent) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(event)
        guard let str = String(data: data, encoding: .utf8) else {
            throw DMError.serializationFailed
        }
        return str
    }

    private func generateRandomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes
    }
}

// MARK: - Decrypted DM Model

struct DecryptedDM: Identifiable, Sendable {
    let rawEventId: String
    let senderPubkeyHex: String
    let recipientPubkeyHex: String
    let content: String
    let createdAt: Date
    let encryption: EncryptionType
    let isFromMe: Bool

    var id: String { rawEventId }

    enum EncryptionType: String, Sendable {
        case nip04
        case nip44
    }
}

// MARK: - DM Errors

enum DMError: LocalizedError {
    case allSendsFailed(String)
    case serializationFailed

    var errorDescription: String? {
        switch self {
        case .allSendsFailed(let detail): return "All relay sends failed: \(detail)"
        case .serializationFailed: return "Event serialization failed"
        }
    }
}

// MARK: - Safe Array Index

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
