import DPYCAuthKit
import XCTest

final class AuthWireContractTests: XCTestCase {

    private let patronPub = String(repeating: "b", count: 64)
    private let operatorPub = String(repeating: "c", count: 64)

    private func makeRequest(
        expiresAt: Int = Int(Date().timeIntervalSince1970) + 300
    ) -> AuthRequest {
        AuthRequest(
            operatorNpub: "npub1exampleoperator",
            operatorName: "Personal Brain",
            dpopToken: "bold-hawk-55",
            offers: [
                AuthOffer(id: "hour", label: "Approve · 1 hour", validSeconds: 3600),
                AuthOffer(id: "day", label: "Approve · all day", validSeconds: 57600),
            ],
            defaultOffer: "hour",
            expiresAt: expiresAt,
            replyRelay: "wss://relay.damus.io"
        )
    }

    // MARK: - Codable round-trips (frozen snake_case contract)

    func testAuthRequestEncodesFrozenSnakeCaseKeys() throws {
        let request = makeRequest()
        let rumor = try request.rumor(operatorPubKeyHex: operatorPub, patronPubKeyHex: patronPub)
        let json = rumor.content

        for key in ["\"v\":", "\"type\":\"auth-request\"", "\"request_id\":",
                    "\"operator_npub\":", "\"operator_name\":", "\"dpop_token\":",
                    "\"offers\":", "\"valid_seconds\":", "\"label\":",
                    "\"default_offer\":", "\"nonce\":", "\"expires_at\":", "\"reply_relay\":"] {
            XCTAssertTrue(json.contains(key), "auth-request JSON must carry \(key) — got: \(json)")
        }
        XCTAssertTrue(json.contains("wss://relay.damus.io"), "reply_relay URL must not be slash-escaped")

        let reparsed = try AuthRequest(rumor: rumor)
        XCTAssertEqual(reparsed, request, "Round-trip must preserve the request exactly")
    }

    func testAuthResponseEncodesFrozenSnakeCaseKeys() throws {
        let request = makeRequest()
        let response = AuthResponse(request: request, choice: "day")
        let rumor = try response.rumor(patronPubKeyHex: patronPub, operatorPubKeyHex: operatorPub)
        let json = rumor.content

        for key in ["\"v\":", "\"type\":\"auth-response\"", "\"request_id\":",
                    "\"dpop_token\":", "\"choice\":\"day\"", "\"nonce\":"] {
            XCTAssertTrue(json.contains(key), "auth-response JSON must carry \(key) — got: \(json)")
        }

        let reparsed = try AuthResponse(rumor: rumor)
        XCTAssertEqual(reparsed, response, "Round-trip must preserve the response exactly")
    }

    /// Decode the frozen-spec sample verbatim (concrete values substituted).
    func testDecodesFrozenSpecSample() throws {
        let sample = """
        {"v":1,"type":"auth-request","request_id":"3f2a1d9c-0b7e-4a55-9c1d-8e6f2b3a4c5d",\
        "operator_npub":"npub1example","operator_name":"Personal Brain",\
        "dpop_token":"bold-hawk-55",\
        "offers":[{"id":"hour","label":"Approve · 1 hour","valid_seconds":3600},\
        {"id":"day","label":"Approve · all day","valid_seconds":57600}],\
        "default_offer":"hour",\
        "nonce":"aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899",\
        "expires_at":1751600000,"reply_relay":"wss://relay.damus.io"}
        """
        let request = try JSONDecoder().decode(AuthRequest.self, from: Data(sample.utf8))
        XCTAssertEqual(request.dpopToken, "bold-hawk-55")
        XCTAssertEqual(request.offers.count, 2)
        XCTAssertEqual(request.offers[1].validSeconds, 57600)
        XCTAssertEqual(request.defaultOffer, "hour")
        XCTAssertEqual(request.replyRelay, "wss://relay.damus.io")
        XCTAssertEqual(request.expiresAt, 1751600000)
    }

    // MARK: - Rumor kinds and parser gates

    func testRumorKindsMatchFrozenContract() throws {
        let request = makeRequest()
        let requestRumor = try request.rumor(operatorPubKeyHex: operatorPub, patronPubKeyHex: patronPub)
        XCTAssertEqual(requestRumor.kind, 24135)
        XCTAssertEqual(requestRumor.tags, [["p", patronPub]], "auth-request p-tags the patron")
        XCTAssertEqual(requestRumor.sig, "", "Rumors are unsigned")

        let response = AuthResponse(request: request, choice: "hour")
        let responseRumor = try response.rumor(patronPubKeyHex: patronPub, operatorPubKeyHex: operatorPub)
        XCTAssertEqual(responseRumor.kind, 24136)
        XCTAssertEqual(responseRumor.tags, [["p", operatorPub]], "auth-response p-tags the operator")
    }

    func testParserRejectsWrongKind() throws {
        let request = makeRequest()
        let rumor = try request.rumor(operatorPubKeyHex: operatorPub, patronPubKeyHex: patronPub)
        XCTAssertThrowsError(try AuthResponse(rumor: rumor)) { error in
            XCTAssertEqual(error as? AuthError, .kindMismatch(expected: 24136, got: 24135))
        }
    }

    func testParserRejectsWrongType() throws {
        // A kind-24135 rumor whose content claims to be an auth-response.
        let request = makeRequest()
        let response = AuthResponse(request: request, choice: "hour")
        let responseJSON = try JSONEncoder().encode(response)
        let rumor = try NostrEvent.rumor(
            kind: .authRequest,
            content: String(data: responseJSON, encoding: .utf8)!,
            tags: [["p", patronPub]],
            publicKeyHex: operatorPub
        )
        XCTAssertThrowsError(try AuthRequest(rumor: rumor)) { error in
            // The content decodes as a different shape → malformed, or decodes
            // with wrong type → typeMismatch. Either way it must throw AuthError.
            XCTAssertNotNil(error as? AuthError)
        }
    }

    func testParserRejectsUnsupportedVersion() throws {
        let sample = """
        {"v":2,"type":"auth-response","request_id":"r1","dpop_token":"t","choice":"hour","nonce":"n"}
        """
        let rumor = try NostrEvent.rumor(
            kind: .authResponse, content: sample, tags: [["p", operatorPub]], publicKeyHex: patronPub
        )
        XCTAssertThrowsError(try AuthResponse(rumor: rumor)) { error in
            XCTAssertEqual(error as? AuthError, .unsupportedVersion(2))
        }
    }

    func testParserRejectsGarbageContent() throws {
        let rumor = try NostrEvent.rumor(
            kind: .authRequest, content: "not json at all", tags: [["p", patronPub]], publicKeyHex: operatorPub
        )
        XCTAssertThrowsError(try AuthRequest(rumor: rumor)) { error in
            XCTAssertEqual(error as? AuthError, .malformedContent)
        }
    }

    // MARK: - Validation semantics

    func testValidateGrantsEachAuthoredOffer() throws {
        let request = makeRequest()

        let hour = try request.validate(AuthResponse(request: request, choice: "hour"))
        XCTAssertEqual(hour?.validSeconds, 3600)

        let day = try request.validate(AuthResponse(request: request, choice: "day"))
        XCTAssertEqual(day?.validSeconds, 57600)
    }

    func testValidateAcceptsExplicitReject() throws {
        let request = makeRequest()
        let response = AuthResponse(request: request, choice: AuthResponse.rejectChoice)
        XCTAssertTrue(response.isRejection)
        let granted = try request.validate(response)
        XCTAssertNil(granted, "Reject grants nothing")
    }

    func testValidateRejectsUnknownChoice() throws {
        let request = makeRequest()
        let response = AuthResponse(request: request, choice: "forever")
        XCTAssertThrowsError(try request.validate(response)) { error in
            XCTAssertEqual(error as? AuthError, .unknownChoice("forever"),
                           "A response can never grant a window that was not offered")
        }
    }

    func testValidateRejectsExpiredRequest() throws {
        let request = makeRequest(expiresAt: Int(Date().timeIntervalSince1970) - 1)
        XCTAssertTrue(request.isExpired())
        let response = AuthResponse(request: request, choice: "hour")
        XCTAssertThrowsError(try request.validate(response)) { error in
            XCTAssertEqual(error as? AuthError, .expired, "A stale approval must not grant")
        }
    }

    func testValidateRejectsEchoMismatches() throws {
        let request = makeRequest()
        let other = makeRequest()  // fresh request_id + nonce

        // request_id mismatch
        XCTAssertThrowsError(try request.validate(AuthResponse(request: other, choice: "hour"))) { error in
            XCTAssertEqual(error as? AuthError, .requestIdMismatch)
        }

        // nonce mismatch: hand-craft a response echoing the right ids but wrong nonce
        let forged = """
        {"v":1,"type":"auth-response","request_id":"\(request.requestId)",\
        "dpop_token":"\(request.dpopToken)","choice":"hour","nonce":"deadbeef"}
        """
        let forgedResponse = try JSONDecoder().decode(AuthResponse.self, from: Data(forged.utf8))
        XCTAssertThrowsError(try request.validate(forgedResponse)) { error in
            XCTAssertEqual(error as? AuthError, .nonceMismatch)
        }

        // dpop_token mismatch
        let wrongToken = """
        {"v":1,"type":"auth-response","request_id":"\(request.requestId)",\
        "dpop_token":"other-token","choice":"hour","nonce":"\(request.nonce)"}
        """
        let wrongTokenResponse = try JSONDecoder().decode(AuthResponse.self, from: Data(wrongToken.utf8))
        XCTAssertThrowsError(try request.validate(wrongTokenResponse)) { error in
            XCTAssertEqual(error as? AuthError, .dpopTokenMismatch)
        }
    }

    func testRequestDefaultsAreWellFormed() {
        let request = makeRequest()
        XCTAssertEqual(request.v, 1)
        XCTAssertEqual(request.type, "auth-request")
        XCTAssertEqual(request.nonce.count, 64, "Nonce is 32 random bytes hex-encoded")
        XCTAssertNotNil(UUID(uuidString: request.requestId), "request_id is a UUID")
        XCTAssertNotEqual(makeRequest().nonce, request.nonce, "Nonces are single-use random")
    }
}
