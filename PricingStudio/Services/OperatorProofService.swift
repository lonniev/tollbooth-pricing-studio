import DPYCAuthKit
import Foundation

/// Signs kind-27235 Nostr events (NIP-98 style) to prove operator identity.
///
/// The proof is sent alongside RESTRICTED MCP tool calls so the server can
/// verify operator authority without rebinding the patron session.
enum OperatorProofService {

    enum ProofError: LocalizedError {
        case noNsecFound
        case keyDerivationFailed
        case signingFailed

        var errorDescription: String? {
            switch self {
            case .noNsecFound: return "No nsec found in Keychain for this npub"
            case .keyDerivationFailed: return "Failed to derive keys from nsec"
            case .signingFailed: return "Failed to sign operator proof event"
            }
        }
    }

    /// Create a signed kind-27235 proof event for a RESTRICTED tool call.
    ///
    /// - Parameters:
    ///   - toolName: The MCP tool name (placed in the `u` tag).
    ///   - operatorNpub: The operator's npub whose nsec is in Keychain.
    /// - Returns: JSON string of the signed Nostr event.
    static func createProof(toolName: String, operatorNpub: String) throws -> String {
        guard let nsec = KeychainService.loadNsec(forNpub: operatorNpub) else {
            throw ProofError.noNsecFound
        }

        let privateKeyHex = try NostrKeyService.privateKeyHexFromNsec(nsec)
        let publicKeyHex = try NostrKeyService.publicKeyHexFromNpub(operatorNpub)

        let event = try NostrEvent.signed(
            kind: .httpAuth,
            content: "",
            tags: [["u", toolName]],
            privateKeyHex: privateKeyHex,
            publicKeyHex: publicKeyHex
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(event)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ProofError.signingFailed
        }
        return json
    }
}
