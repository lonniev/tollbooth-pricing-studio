import CryptoKit
import Foundation
import P256K

/// Signing a Cashu escrow move with a person's own Nostr key, without signing
/// blind.
///
/// An escrow move (fund it, agree a split, collect a share) needs a BIP-340
/// signature over the sha256 of a Cashu message. Signing a 32-byte digest an
/// operator hands over would let a bad operator slip in the id of a Nostr event
/// (a profile change, a login elsewhere) and get it signed. So the message is
/// rebuilt here from its parts and checked, and only the sha256 of the rebuild
/// is signed:
///
/// - `mint_quote` (NUT-20): the quote id and blinded outputs, all new sats going
///   into the escrow;
/// - `swap` / `melt` (NUT-11 SIG_ALL): inputs locked to the signer's own key,
///   paying out no more than they hold.
///
/// The same check as `@tollbooth-dpyc/web`'s `escrowSigning.ts`, held to the same
/// vectors. What it cannot prove: the outputs are blinded, so who receives each
/// share rests on the operator's word, which the screen shows beside the button.
public enum EscrowSigning {

    public enum Kind: String, Codable, Sendable { case mintQuote = "mint_quote", swap, melt }

    public enum Move: String, Codable, Sendable { case fund, proposal, collect }

    public struct Input: Codable, Sendable, Equatable {
        public let amount: Int
        public let secret: String
        public let C: String
    }

    public struct Output: Codable, Sendable, Equatable {
        public let amount: Int
        public let B_: String
    }

    /// What an escrow message is built from, as the operator hands it out.
    public struct Parts: Codable, Sendable, Equatable {
        public let kind: Kind
        public let inputs: [Input]
        public let outputs: [Output]
        public let quote: String
    }

    /// One thing waiting on the signer, as `escrow_status` lists it in `for_you`.
    public struct Signable: Codable, Sendable, Equatable {
        public let what: Move
        public let role: String?
        public let sign_digest: String
        public let parts: Parts
        public let sats: Int?
        public let fee_reserve: Int?
        public let to_performer: Int?
        public let to_purchaser: Int?
    }

    /// Why a message is refused; the description is a plain sentence.
    public enum Refusal: Error, Equatable, LocalizedError {
        case notAnNpub, wrongKind, incomplete, notAnOutput, notAProof, notYourLock
        case paysMoreThanItSpends, quoteMisplaced, moreThanHeld, readsAsNostrEvent, digestMismatch, notYourKey

        public var errorDescription: String? {
            switch self {
            case .notAnNpub: return "That is not an npub."
            case .wrongKind: return "This is not the kind of message this move signs."
            case .incomplete: return "The message to sign is incomplete."
            case .notAnOutput: return "The message pays out to something that is not a Cashu output."
            case .notAProof: return "The message spends something that is not a Cashu proof."
            case .notYourLock: return "The message spends sats that are not locked to your key."
            case .paysMoreThanItSpends: return "The message pays out more than it spends."
            case .quoteMisplaced: return "Only a payout names a Lightning quote."
            case .moreThanHeld: return "The message moves more sats than this escrow holds for it."
            case .readsAsNostrEvent: return "That reads as a Nostr event."
            case .digestMismatch: return "The operator's digest does not match the message; nothing was signed."
            case .notYourKey: return "This key is not that npub's."
            }
        }
    }

    private static let kindOf: [Move: Kind] = [.fund: .mintQuote, .proposal: .swap, .collect: .melt]

    private static func isPoint(_ hex: String) -> Bool {
        let h = hex.lowercased()
        return h.count == 66 && (h.hasPrefix("02") || h.hasPrefix("03")) && Data(hexString: h) != nil
    }

    private static func len32(_ n: Int) -> Data {
        Data([UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
    }

    /// An amount as NUT-20 writes it: big-endian, as few bytes as it needs.
    private static func amountBytes(_ amount: Int) -> Data {
        var out: [UInt8] = []
        var v = UInt64(amount)
        while v > 0 { out.insert(UInt8(v & 255), at: 0); v >>= 8 }
        return Data(out)
    }

    /// The message the parts make, byte for byte as the mint checks it.
    public static func message(_ parts: Parts) -> Data {
        if parts.kind == .mintQuote {
            let quote = Data(parts.quote.utf8)
            var msg = Data("Cashu_MintQuoteSig_v1".utf8) + len32(quote.count) + quote
            for o in parts.outputs {
                let amt = amountBytes(o.amount)
                let b = Data(hexString: o.B_) ?? Data()
                msg += len32(amt.count) + amt + len32(b.count) + b
            }
            return msg
        }
        let text = parts.inputs.map { $0.secret + $0.C }.joined()
            + parts.outputs.map { "\($0.amount)\($0.B_)" }.joined()
            + (parts.kind == .melt ? parts.quote : "")
        return Data(text.utf8)
    }

    /// True when a NUT-10 secret is a P2PK lock naming `xonly` as data, a signer or a refund key.
    static func locks(_ secret: String, to xonly: String) -> Bool {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(secret.utf8)) as? [Any],
              parsed.count == 2, parsed[0] as? String == "P2PK",
              let body = parsed[1] as? [String: Any] else { return false }
        var keys: [Any] = [body["data"] as Any]
        for tag in body["tags"] as? [[Any]] ?? [] {
            if let name = tag.first as? String, name == "pubkeys" || name == "refund" { keys += tag.dropFirst() }
        }
        return keys.contains { key in
            guard let k = (key as? String)?.lowercased(), isPoint(k) else { return false }
            return String(k.suffix(64)) == xonly
        }
    }

    /// The 32-byte digest `npub` may sign for this item, rebuilt here. `most` is
    /// the most the move may pay out: the escrow's sats to fund it, what it holds
    /// to split it, the share to collect it.
    public static func checkedDigest(_ item: Signable, npub: String, most: Int) throws -> Data {
        guard let xonly = try? NostrKeyService.publicKeyHexFromNpub(npub).lowercased() else { throw Refusal.notAnNpub }
        let parts = item.parts
        guard kindOf[item.what] == parts.kind else { throw Refusal.wrongKind }
        guard !parts.outputs.isEmpty, parts.outputs.allSatisfy({ $0.amount > 0 && isPoint($0.B_) }) else {
            throw Refusal.notAnOutput
        }
        let out = parts.outputs.reduce(0) { $0 + $1.amount }
        if parts.kind == .mintQuote {
            guard parts.inputs.isEmpty, !parts.quote.isEmpty else { throw Refusal.incomplete }
        } else {
            guard !parts.inputs.isEmpty, parts.inputs.allSatisfy({ $0.amount > 0 && isPoint($0.C) }) else {
                throw Refusal.notAProof
            }
            guard parts.inputs.allSatisfy({ locks($0.secret, to: xonly) }) else { throw Refusal.notYourLock }
            guard out <= parts.inputs.reduce(0, { $0 + $1.amount }) else { throw Refusal.paysMoreThanItSpends }
            guard (parts.kind == .melt) == !parts.quote.isEmpty else { throw Refusal.quoteMisplaced }
        }
        guard out <= most else { throw Refusal.moreThanHeld }
        let msg = message(parts)
        guard !msg.starts(with: Data("[0,".utf8)) else { throw Refusal.readsAsNostrEvent }
        let digest = Data(SHA256.hash(data: msg))
        guard digest.hexString == item.sign_digest.lowercased() else { throw Refusal.digestMismatch }
        return digest
    }

    /// A BIP-340 signature (128 hex) by `privateKeyHex` on the checked message.
    public static func sign(_ item: Signable, npub: String, most: Int, privateKeyHex: String) throws -> String {
        guard let raw = Data(hexString: privateKeyHex), raw.count == 32,
              let key = try? P256K.Schnorr.PrivateKey(dataRepresentation: Array(raw)),
              let xonly = try? NostrKeyService.publicKeyHexFromNpub(npub).lowercased(),
              Data(key.xonly.bytes).hexString == xonly else { throw Refusal.notYourKey }
        let digest = try checkedDigest(item, npub: npub, most: most)
        return try signEventId(digest.hexString, privateKeyHex: privateKeyHex)
    }
}
