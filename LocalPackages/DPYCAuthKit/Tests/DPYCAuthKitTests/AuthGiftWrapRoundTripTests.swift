import DPYCAuthKit
import XCTest

/// End-to-end frozen-contract exercise: Operator builds an auth-request,
/// gift-wraps it to the Patron; Patron unwraps, parses, answers; Operator
/// unwraps the auth-response and validates it against the outstanding request.
final class AuthGiftWrapRoundTripTests: XCTestCase {

    private var operatorPriv = ""
    private var operatorPub = ""
    private var operatorNpub = ""
    private var patronPriv = ""
    private var patronPub = ""

    override func setUpWithError() throws {
        let op = try NostrKeyService.generateKeyPair()
        let patron = try NostrKeyService.generateKeyPair()
        operatorNpub = op.npub
        operatorPriv = try NostrKeyService.privateKeyHexFromNsec(op.nsec)
        operatorPub = try NostrKeyService.publicKeyHexFromNpub(op.npub)
        patronPriv = try NostrKeyService.privateKeyHexFromNsec(patron.nsec)
        patronPub = try NostrKeyService.publicKeyHexFromNpub(patron.npub)
    }

    private func makeRequest() -> AuthRequest {
        AuthRequest(
            operatorNpub: operatorNpub,
            operatorName: "Personal Brain",
            dpopToken: "bold-hawk-55",
            offers: [
                AuthOffer(id: "hour", label: "Approve · 1 hour", validSeconds: 3600),
                AuthOffer(id: "day", label: "Approve · all day", validSeconds: 57600),
            ],
            defaultOffer: "hour",
            expiresAt: Int(Date().timeIntervalSince1970) + 300,
            replyRelay: "wss://relay.damus.io"
        )
    }

    func testFullApprovalRoundTrip() throws {
        // Operator → Patron: build, wrap, "send".
        let request = makeRequest()
        let requestWrap = try GiftWrap.wrap(
            rumor: try request.rumor(operatorPubKeyHex: operatorPub, patronPubKeyHex: patronPub),
            senderPrivKeyHex: operatorPriv,
            senderPubKeyHex: operatorPub,
            recipientPubKeyHex: patronPub
        )
        XCTAssertEqual(requestWrap.kind, NostrEventKind.giftWrap.rawValue)
        XCTAssertEqual(requestWrap.tags, [["p", patronPub]], "Relay routing p-tag targets the patron")

        // Patron side: unwrap, verify authorship, parse, decide.
        let unwrappedRequest = try GiftWrap.unwrap(requestWrap, recipientPrivateKeyHex: patronPriv)
        XCTAssertEqual(unwrappedRequest.sealPubkey, operatorPub,
                       "Seal signature is the proof the operator sent this")
        let received = try AuthRequest(rumor: unwrappedRequest.rumor)
        XCTAssertEqual(received, request)
        XCTAssertFalse(received.isExpired())

        // Patron answers with the default offer (the double-tap path).
        let response = AuthResponse(request: received, choice: received.defaultOffer)
        let responseWrap = try GiftWrap.wrap(
            rumor: try response.rumor(patronPubKeyHex: patronPub, operatorPubKeyHex: operatorPub),
            senderPrivKeyHex: patronPriv,
            senderPubKeyHex: patronPub,
            recipientPubKeyHex: operatorPub
        )

        // Operator side: unwrap, check the seal is the challenged patron, validate.
        let unwrappedResponse = try GiftWrap.unwrap(responseWrap, recipientPrivateKeyHex: operatorPriv)
        XCTAssertEqual(unwrappedResponse.sealPubkey, patronPub,
                       "Operator must verify the seal pubkey is the challenged patron")
        let receivedResponse = try AuthResponse(rumor: unwrappedResponse.rumor)
        let granted = try request.validate(receivedResponse)
        XCTAssertEqual(granted?.id, "hour")
        XCTAssertEqual(granted?.validSeconds, 3600, "Grant duration comes from the authored offer")
        XCTAssertEqual(receivedResponse.dpopToken, "bold-hawk-55")
    }

    func testFullRejectionRoundTrip() throws {
        let request = makeRequest()
        let requestWrap = try GiftWrap.wrap(
            rumor: try request.rumor(operatorPubKeyHex: operatorPub, patronPubKeyHex: patronPub),
            senderPrivKeyHex: operatorPriv,
            senderPubKeyHex: operatorPub,
            recipientPubKeyHex: patronPub
        )

        let received = try AuthRequest(rumor: try GiftWrap.unwrap(requestWrap, recipientPrivateKeyHex: patronPriv).rumor)
        let response = AuthResponse(request: received, choice: AuthResponse.rejectChoice)
        let responseWrap = try GiftWrap.wrap(
            rumor: try response.rumor(patronPubKeyHex: patronPub, operatorPubKeyHex: operatorPub),
            senderPrivKeyHex: patronPriv,
            senderPubKeyHex: patronPub,
            recipientPubKeyHex: operatorPub
        )

        let receivedResponse = try AuthResponse(
            rumor: try GiftWrap.unwrap(responseWrap, recipientPrivateKeyHex: operatorPriv).rumor
        )
        XCTAssertTrue(receivedResponse.isRejection)
        XCTAssertNil(try request.validate(receivedResponse), "Explicit reject grants nothing")
    }

    func testImpostorResponseFailsSealCheck() throws {
        // Mallory answers Bob's challenge with her own key: the wrap unwraps
        // fine, but the seal pubkey is not the challenged patron.
        let mallory = try NostrKeyService.generateKeyPair()
        let malloryPriv = try NostrKeyService.privateKeyHexFromNsec(mallory.nsec)
        let malloryPub = try NostrKeyService.publicKeyHexFromNpub(mallory.npub)

        let request = makeRequest()
        let response = AuthResponse(request: request, choice: "day")
        let responseWrap = try GiftWrap.wrap(
            rumor: try response.rumor(patronPubKeyHex: malloryPub, operatorPubKeyHex: operatorPub),
            senderPrivKeyHex: malloryPriv,
            senderPubKeyHex: malloryPub,
            recipientPubKeyHex: operatorPub
        )

        let unwrapped = try GiftWrap.unwrap(responseWrap, recipientPrivateKeyHex: operatorPriv)
        XCTAssertNotEqual(unwrapped.sealPubkey, patronPub,
                          "The operator-side seal-vs-challenged-patron comparison catches the impostor")
    }
}
