import DPYCAuthKit
import XCTest

final class GiftWrapTests: XCTestCase {

    private var alicePriv = ""
    private var alicePub = ""
    private var bobPriv = ""
    private var bobPub = ""

    override func setUpWithError() throws {
        let alice = try NostrKeyService.generateKeyPair()
        let bob = try NostrKeyService.generateKeyPair()
        alicePriv = try NostrKeyService.privateKeyHexFromNsec(alice.nsec)
        alicePub = try NostrKeyService.publicKeyHexFromNpub(alice.npub)
        bobPriv = try NostrKeyService.privateKeyHexFromNsec(bob.nsec)
        bobPub = try NostrKeyService.publicKeyHexFromNpub(bob.npub)
    }

    func testDMWrapUnwrapRoundTrip() throws {
        let wrap = try GiftWrap.wrapDM(
            message: "gift wrapped hello",
            senderPrivKeyHex: alicePriv,
            senderPubKeyHex: alicePub,
            recipientPubKeyHex: bobPub
        )
        XCTAssertEqual(wrap.kind, NostrEventKind.giftWrap.rawValue)
        XCTAssertNotEqual(wrap.pubkey, alicePub, "Wrap must be signed by an ephemeral key, not the sender")

        let dm = GiftWrap.unwrapDM(wrap, privateKeyHex: bobPriv, publicKeyHex: bobPub)
        XCTAssertEqual(dm?.content, "gift wrapped hello")
        XCTAssertEqual(dm?.senderPubkeyHex, alicePub)
        XCTAssertEqual(dm?.recipientPubkeyHex, bobPub)
        XCTAssertEqual(dm?.encryption, .nip44)
        XCTAssertEqual(dm?.isFromMe, false)
    }

    func testDMCarriesItsRumorTagsAndRumorId() throws {
        let wrap = try GiftWrap.wrapDM(
            message: "{}",
            senderPrivKeyHex: alicePriv,
            senderPubKeyHex: alicePub,
            recipientPubKeyHex: bobPub,
            extraTags: [["e", String(repeating: "c", count: 64)]]
        )
        let dm = try XCTUnwrap(GiftWrap.unwrapDM(wrap, privateKeyHex: bobPriv, publicKeyHex: bobPub))
        XCTAssertEqual(dm.tags, [["p", bobPub], ["e", String(repeating: "c", count: 64)]])

        let rumor = try GiftWrap.unwrap(wrap, recipientPrivateKeyHex: bobPriv).rumor
        XCTAssertEqual(dm.messageId, rumor.id, "The DM names its rumor, not the wrap")
        XCTAssertNotEqual(dm.messageId, wrap.id)
        XCTAssertEqual(dm.messageId.count, 64)
    }

    /// The vector comes from tollbooth-dpyc `_rumor_id` (Python), so the id a
    /// reply quotes matches the one the SDK gave its request: slashes, a dash
    /// outside ASCII and a newline all serialize the same on both sides.
    func testRumorIdMatchesTheSDK() throws {
        let id = try computeEventId(
            pubkey: String(repeating: "a", count: 64),
            createdAt: 1_762_500_000,
            kind: 14,
            tags: [
                ["p", String(repeating: "b", count: 64)],
                ["form", #"{"title":"Npub ownership — proof","relay":"wss://relay.example"}"#],
            ],
            content: "Hi\nconfirm = @@@x@@@"
        )
        XCTAssertEqual(id, "7272f650db6b3e23001518a2dcdc405f3234c59284e470457a66de02625919fb")
    }

    func testUnwrapExposesSealPubkey() throws {
        let rumor = try NostrEvent.rumor(
            kind: .privateDM,
            content: "who signed this?",
            tags: [["p", bobPub]],
            publicKeyHex: alicePub
        )
        let wrap = try GiftWrap.wrap(
            rumor: rumor,
            senderPrivKeyHex: alicePriv,
            senderPubKeyHex: alicePub,
            recipientPubKeyHex: bobPub
        )
        let unwrapped = try GiftWrap.unwrap(wrap, recipientPrivateKeyHex: bobPriv)
        XCTAssertEqual(unwrapped.sealPubkey, alicePub, "Seal pubkey is the authorship proof")
        XCTAssertEqual(unwrapped.rumor.pubkey, alicePub)
        XCTAssertEqual(unwrapped.rumor.content, "who signed this?")
    }

    func testWrongRecipientCannotUnwrap() throws {
        let carol = try NostrKeyService.generateKeyPair()
        let carolPriv = try NostrKeyService.privateKeyHexFromNsec(carol.nsec)

        let wrap = try GiftWrap.wrapDM(
            message: "for bob only",
            senderPrivKeyHex: alicePriv,
            senderPubKeyHex: alicePub,
            recipientPubKeyHex: bobPub
        )
        XCTAssertThrowsError(try GiftWrap.unwrap(wrap, recipientPrivateKeyHex: carolPriv))
    }

    func testNonGiftWrapKindRejected() throws {
        let plain = try NostrEvent.signed(
            kind: .encryptedDM,
            content: "not a wrap",
            tags: [],
            privateKeyHex: alicePriv,
            publicKeyHex: alicePub
        )
        XCTAssertThrowsError(try GiftWrap.unwrap(plain, recipientPrivateKeyHex: bobPriv)) { error in
            XCTAssertEqual(error as? GiftWrapError, .invalidWrapKind(NostrEventKind.encryptedDM.rawValue))
        }
    }

    func testTamperedSealKindRejected() throws {
        // Hand-build a wrap whose "seal" is kind 4 instead of 13.
        let rumor = try NostrEvent.rumor(
            kind: .privateDM, content: "x", tags: [["p", bobPub]], publicKeyHex: alicePub
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let rumorJSON = String(data: try encoder.encode(rumor), encoding: .utf8)!

        let sealContent = try NIP44Service.encrypt(rumorJSON, privateKeyHex: alicePriv, publicKeyHex: bobPub)
        let badSeal = try NostrEvent.signed(
            kind: .encryptedDM,  // wrong kind — must be .seal
            content: sealContent,
            tags: [],
            privateKeyHex: alicePriv,
            publicKeyHex: alicePub
        )
        let sealJSON = String(data: try encoder.encode(badSeal), encoding: .utf8)!

        let ephemeral = try NostrKeyService.generateKeyPair()
        let ephPriv = try NostrKeyService.privateKeyHexFromNsec(ephemeral.nsec)
        let ephPub = try NostrKeyService.publicKeyHexFromNpub(ephemeral.npub)
        let wrapContent = try NIP44Service.encrypt(sealJSON, privateKeyHex: ephPriv, publicKeyHex: bobPub)
        let wrap = try NostrEvent.signed(
            kind: .giftWrap,
            content: wrapContent,
            tags: [["p", bobPub]],
            privateKeyHex: ephPriv,
            publicKeyHex: ephPub
        )

        XCTAssertThrowsError(try GiftWrap.unwrap(wrap, recipientPrivateKeyHex: bobPriv)) { error in
            XCTAssertEqual(error as? GiftWrapError, .invalidSeal)
        }
    }

    func testRumorSealAuthorMismatchRejected() throws {
        // Alice seals a rumor claiming Carol authored it — impersonation.
        let carol = try NostrKeyService.generateKeyPair()
        let carolPub = try NostrKeyService.publicKeyHexFromNpub(carol.npub)

        let forgedRumor = try NostrEvent.rumor(
            kind: .privateDM,
            content: "I am totally Carol",
            tags: [["p", bobPub]],
            publicKeyHex: carolPub
        )
        let wrap = try GiftWrap.wrap(
            rumor: forgedRumor,
            senderPrivKeyHex: alicePriv,
            senderPubKeyHex: alicePub,
            recipientPubKeyHex: bobPub
        )
        XCTAssertThrowsError(try GiftWrap.unwrap(wrap, recipientPrivateKeyHex: bobPriv)) { error in
            XCTAssertEqual(error as? GiftWrapError, .rumorSealAuthorMismatch)
        }
    }

    func testWrapTimestampIsFuzzedIntoPast() throws {
        let before = Int(Date().timeIntervalSince1970)
        let wrap = try GiftWrap.wrapDM(
            message: "when was this?",
            senderPrivKeyHex: alicePriv,
            senderPubKeyHex: alicePub,
            recipientPubKeyHex: bobPub
        )
        let after = Int(Date().timeIntervalSince1970)
        let fuzzWindow = 2 * 24 * 60 * 60
        XCTAssertLessThanOrEqual(wrap.created_at, after, "Wrap timestamp must never be in the future")
        XCTAssertGreaterThanOrEqual(wrap.created_at, before - fuzzWindow, "Wrap timestamp fuzz is at most 48h into the past")
    }

    func testDMRecoversRealSendTimeNotFuzzedTimestamp() throws {
        let wrap = try GiftWrap.wrapDM(
            message: "timely",
            senderPrivKeyHex: alicePriv,
            senderPubKeyHex: alicePub,
            recipientPubKeyHex: bobPub
        )
        let sentAt = Date()
        let dm = try XCTUnwrap(GiftWrap.unwrapDM(wrap, privateKeyHex: bobPriv, publicKeyHex: bobPub))
        XCTAssertLessThan(abs(dm.createdAt.timeIntervalSince(sentAt)), 60,
                          "DM timestamp should be the rumor's real send time, not the fuzzed wrap time")
    }
}
