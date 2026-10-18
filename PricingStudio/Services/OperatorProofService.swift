import CryptoKit
import DPYCAuthKit
import Foundation

/// Signs kind-27235 Nostr events (NIP-98) with an nsec held in the Keychain.
///
/// A request signed this way proves its npub on the connection; whoever holds
/// the nsec needs no grant.
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

    /// True when the Keychain holds `npub`'s nsec, so its requests can be signed.
    static func holdsKey(for npub: String) -> Bool {
        KeychainService.loadNsec(forNpub: npub) != nil
    }

    /// The `Authorization` value for one request signed by `npub` (NIP-98).
    ///
    /// The event names the method, the URL and the sha256 of the body, so it
    /// authorizes this request and nothing else. A random `nonce` tag keeps two
    /// identical requests within one second distinct; the operator accepts
    /// each event once.
    static func signRequest(_ request: URLRequest, as npub: String) throws -> String {
        let body = request.httpBody ?? Data()
        let tags = [
            ["u", request.url?.absoluteString ?? ""],
            ["method", (request.httpMethod ?? "GET").uppercased()],
            ["payload", SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()],
            ["nonce", UUID().uuidString],
        ]
        return "Nostr " + Data(try signedEvent(tags: tags, npub: npub).utf8).base64EncodedString()
    }

    private static func signedEvent(tags: [[String]], npub operatorNpub: String) throws -> String {
        guard let nsec = KeychainService.loadNsec(forNpub: operatorNpub) else {
            throw ProofError.noNsecFound
        }

        let privateKeyHex = try NostrKeyService.privateKeyHexFromNsec(nsec)
        let publicKeyHex = try NostrKeyService.publicKeyHexFromNpub(operatorNpub)

        let event = try NostrEvent.signed(
            kind: .httpAuth,
            content: "",
            tags: tags,
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
