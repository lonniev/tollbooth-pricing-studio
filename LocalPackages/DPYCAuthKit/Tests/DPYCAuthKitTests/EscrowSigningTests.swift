import CryptoKit
import DPYCAuthKit
import P256K
import XCTest

/// The escrow check against the vectors tollbooth-dpyc's cashu.py made, the same
/// file `@tollbooth-dpyc/web` tests against, so both signers agree with the mint.
final class EscrowSigningTests: XCTestCase {

    struct Vectors: Decodable {
        struct Item: Decodable {
            let signer: String
            let message_hex: String
            let item: EscrowSigning.Signable

            enum CodingKeys: String, CodingKey { case signer, message_hex }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                signer = try c.decode(String.self, forKey: .signer)
                message_hex = try c.decode(String.self, forKey: .message_hex)
                item = try EscrowSigning.Signable(from: decoder)
            }
        }
        let npubs: [String: String]
        let items: [Item]
    }

    var v: Vectors!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "escrowSigning.vectors", withExtension: "json"))
        v = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    /// Test key n is sha256("escrow-vector-<n>"); worker is 1. They hold nothing.
    private func key(_ n: Int) -> String { Data(SHA256.hash(data: Data("escrow-vector-\(n)".utf8))).hexString }

    private var fund: EscrowSigning.Signable { v.items[0].item }
    private var proposal: EscrowSigning.Signable { v.items[1].item }
    private var collect: EscrowSigning.Signable { v.items[2].item }

    /// A copy of `item` with its JSON changed by `edit`.
    private func changed(_ item: EscrowSigning.Signable, _ edit: (inout [String: Any]) -> Void) throws -> EscrowSigning.Signable {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        edit(&json)
        return try JSONDecoder().decode(EscrowSigning.Signable.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func refusal(_ item: EscrowSigning.Signable, _ who: String, most: Int = 1_000) -> EscrowSigning.Refusal? {
        do { _ = try EscrowSigning.checkedDigest(item, npub: v.npubs[who]!, most: most); return nil }
        catch { return error as? EscrowSigning.Refusal }
    }

    func testRebuildsEveryKindByteForByte() {
        for i in v.items { XCTAssertEqual(EscrowSigning.message(i.item.parts).hexString, i.message_hex, i.item.what.rawValue) }
    }

    func testPassesEachVectorForItsSigner() throws {
        for i in v.items {
            let digest = try EscrowSigning.checkedDigest(i.item, npub: v.npubs[i.signer]!, most: 1_000)
            XCTAssertEqual(digest.hexString, i.item.sign_digest)
        }
    }

    func testRefusesSatsNotLockedToTheSigner() {
        XCTAssertEqual(refusal(proposal, "stranger"), .notYourLock)
        XCTAssertEqual(refusal(collect, "client"), .notYourLock)
    }

    func testRefusesAForeignDigest() throws {
        let sneaky = try changed(proposal) { $0["sign_digest"] = String(repeating: "ab", count: 32) }
        XCTAssertEqual(refusal(sneaky, "worker"), .digestMismatch)
        XCTAssertThrowsError(try EscrowSigning.sign(sneaky, npub: v.npubs["worker"]!, most: 1_000, privateKeyHex: key(1)))
    }

    func testRefusesANostrEventDressedAsParts() throws {
        let item = try changed(proposal) { json in
            var parts = json["parts"] as! [String: Any]
            var inputs = parts["inputs"] as! [[String: Any]]
            inputs[0]["secret"] = "[0,\"\(String(repeating: "ab", count: 32))\",1,0,[],\"\"]"
            parts["inputs"] = inputs
            json["parts"] = parts
        }
        XCTAssertNotNil(refusal(item, "worker"))
    }

    func testRefusesMoreThanHeldOrMoreOutThanIn() throws {
        XCTAssertEqual(refusal(fund, "client", most: 26), .moreThanHeld)
        let greedy = try changed(proposal) { json in
            var parts = json["parts"] as! [String: Any]
            var outputs = parts["outputs"] as! [[String: Any]]
            outputs[0]["amount"] = 64
            parts["outputs"] = outputs
            json["parts"] = parts
        }
        XCTAssertEqual(refusal(greedy, "worker"), .paysMoreThanItSpends)
    }

    func testRefusesTheWrongKindForTheMove() throws {
        let item = try changed(proposal) { $0["what"] = "collect" }
        XCTAssertEqual(refusal(item, "worker"), .wrongKind)
    }

    func testSignsTheRebuiltDigestAndItVerifies() throws {
        let sig = try EscrowSigning.sign(proposal, npub: v.npubs["worker"]!, most: 1_000, privateKeyHex: key(1))
        let xonly = try P256K.Schnorr.XonlyKey(dataRepresentation: Array(Data(hexString: NostrKeyService.publicKeyHexFromNpub(v.npubs["worker"]!))!))
        let signature = try P256K.Schnorr.SchnorrSignature(dataRepresentation: Data(hexString: sig)!)
        let digest = Array(Data(hexString: proposal.sign_digest)!)
        XCTAssertTrue(xonly.isValid(signature, for: digest))
    }

    func testRefusesAKeyThatIsNotTheNpubs() {
        XCTAssertThrowsError(try EscrowSigning.sign(proposal, npub: v.npubs["arbiter"]!, most: 1_000, privateKeyHex: key(1))) {
            XCTAssertEqual($0 as? EscrowSigning.Refusal, .notYourKey)
        }
    }
}
