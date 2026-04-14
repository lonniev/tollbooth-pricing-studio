import Foundation

/// Auto-responds to NPUB_PROOF_REQUEST DMs by signing a kind-27235
/// ownership proof and replying via Nostr DM.
///
/// When a DPYC operator sends a proof request to a patron, the patron's
/// PricingStudio app detects the request, signs the proof with the
/// patron's nsec from Keychain, and replies automatically. This lets
/// stateless AI agents (claude.ai, etc.) verify patron identity without
/// the patron needing to manually intervene.
enum NpubProofAutoResponder {

    private static let requestPrefix = "NPUB_PROOF_REQUEST"

    /// Check if a DM is an npub proof request; if so, auto-sign and reply.
    ///
    /// - Parameters:
    ///   - dm: The decrypted inbound DM.
    ///   - recipientNpub: The patron's npub that received the DM.
    ///   - dmService: Service for sending the reply DM.
    /// - Returns: `true` if the DM was a proof request and was handled.
    static func handleIfProofRequest(
        dm: DecryptedDM,
        recipientNpub: String,
        dmService: NostrDMService
    ) async -> Bool {
        guard dm.content.hasPrefix(requestPrefix) else { return false }
        guard !dm.isFromMe else { return false }

        await MainActor.run {
            TrafficLogger.shared.log(
                .inbound, label: "ProofReq",
                detail: "\(recipientNpub.prefix(12))... proof request from \(dm.senderPubkeyHex.prefix(12))..."
            )
        }

        do {
            // Sign a kind-27235 event with u=npub_ownership
            let proofJSON = try OperatorProofService.createProof(
                toolName: "npub_ownership",
                operatorNpub: recipientNpub
            )

            // Derive keys for sending the reply
            guard let nsec = KeychainService.loadNsec(forNpub: recipientNpub) else {
                await MainActor.run {
                    TrafficLogger.shared.log(
                        .error, label: "ProofReq",
                        detail: "\(recipientNpub.prefix(12))... no nsec in Keychain"
                    )
                }
                return false
            }
            let privKeyHex = try NostrKeyService.privateKeyHexFromNsec(nsec)
            let pubKeyHex = try NostrKeyService.publicKeyHexFromNpub(recipientNpub)

            // Reply in Secure Courier @@@ delimited format
            let courierReply = "proof_json = @@@\(proofJSON)@@@"
            try await dmService.sendDM(
                privateKeyHex: privKeyHex,
                publicKeyHex: pubKeyHex,
                recipientPubkeyHex: dm.senderPubkeyHex,
                message: courierReply
            )

            await MainActor.run {
                TrafficLogger.shared.log(
                    .outbound, label: "ProofReq",
                    detail: "\(recipientNpub.prefix(12))... ownership proof sent to \(dm.senderPubkeyHex.prefix(12))..."
                )
            }
            return true
        } catch {
            await MainActor.run {
                TrafficLogger.shared.log(
                    .error, label: "ProofReq",
                    detail: "\(recipientNpub.prefix(12))... failed: \(error.localizedDescription)"
                )
            }
            return false
        }
    }
}
