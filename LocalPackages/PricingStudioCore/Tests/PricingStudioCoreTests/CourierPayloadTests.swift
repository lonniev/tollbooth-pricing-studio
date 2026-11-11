import XCTest
@testable import PricingStudioCore

final class CourierPayloadTests: XCTestCase {

    private let nonce = "bold-hawk-42"
    private let relay = "wss://relay.example"
    private let requestId = String(repeating: "c", count: 64)

    private func credentials(extraTags: [[String]] = []) throws -> CourierPayload {
        try XCTUnwrap(CourierPayload.parse(
            tags: [["p", "aa"], ["form", try CourierFixtures.text("credential_form")]] + extraTags,
            requestId: requestId
        ))
    }

    // MARK: - Reading the form

    func testFormReadsTitleGreetingKindAndService() throws {
        let form = try credentials().form
        XCTAssertEqual(form.title, "Schwab operator credentials")
        XCTAssertEqual(form.description, "Paste your keys below.")
        XCTAssertEqual(form.kind, .credentials)
        XCTAssertEqual(form.service, "schwab-operator")
        XCTAssertEqual(form.delimiter, "@@@")
    }

    func testFieldsKeepTheOperatorsOrderAndHideControlValues() throws {
        let payload = try credentials()
        XCTAssertEqual(payload.fields.map(\.key), ["app_key", "secret", "account_label"])
        XCTAssertEqual(payload.nonce, nonce)
        XCTAssertEqual(payload.rendezvousRelay, URL(string: relay))
    }

    func testSecretsRequiredTitlesAndHelpComeFromTheSchema() throws {
        let fields = try credentials().fields
        let appKey = fields[0].property
        XCTAssertTrue(appKey.isSecret)
        XCTAssertTrue(appKey.isRequired)
        XCTAssertEqual(appKey.title, "App key")
        XCTAssertEqual(appKey.description, "From developer.schwab.com, your app's page")
        let label = fields[2].property
        XCTAssertFalse(label.isSecret)
        XCTAssertFalse(label.isRequired)
        XCTAssertEqual(label.title, "account_label")
    }

    func testApprovalFormOffersDurationChoices() throws {
        let payload = try XCTUnwrap(CourierPayload.parse(
            tags: [["form", try CourierFixtures.text("approval")]], requestId: requestId
        ))
        XCTAssertTrue(payload.isApproval)
        let duration = try XCTUnwrap(payload.fields.first { $0.key == "cache_duration" })
        XCTAssertEqual(duration.value, "2h")
        XCTAssertEqual(duration.property.examples, ["2h", "1d", "1w", "30d"])
    }

    func testAttestationComesFromItsTag() throws {
        XCTAssertNil(try credentials().attestationJSON)
        XCTAssertEqual(try credentials(extraTags: [["attestation", "{\"kind\":27235}"]]).attestationJSON,
                       "{\"kind\":27235}")
    }

    // MARK: - Not a courier request

    func testNoFormTagIsNotARequest() {
        XCTAssertNil(CourierPayload.parse(tags: [["p", "aa"]], requestId: requestId))
    }

    func testTwoFormTagsAreRefused() throws {
        let form = try CourierFixtures.text("credential_form")
        XCTAssertNil(CourierPayload.parse(tags: [["form", form], ["form", form]], requestId: requestId))
    }

    func testFormsOutsideTheSubsetAreRefused() throws {
        let edits: [(String, (inout [String: Any]) -> Void)] = [
            ("unknown kind", { $0["x-courier-kind"] = "survey" }),
            ("nested object", { CourierFixtures.set(&$0, property: "secret", "type", "object") }),
            ("number field", { CourierFixtures.set(&$0, property: "secret", "type", "number") }),
            ("empty nonce", { CourierFixtures.set(&$0, property: "nonce", "const", "") }),
            ("https relay", { CourierFixtures.set(&$0, property: "rendezvous_relay", "const", "https://relay.example") }),
            ("not an object", { $0["type"] = "array" }),
        ]
        for (name, edit) in edits {
            let form = try CourierFixtures.text("credential_form", edit: edit)
            XCTAssertNil(CourierPayload.parse(tags: [["form", form]], requestId: requestId), name)
        }
        XCTAssertNil(CourierPayload.parse(tags: [["form", "not json"]], requestId: requestId))
    }

    // MARK: - Replying

    func testReplyCarriesFilledFieldsAndControlValuesOnly() throws {
        var payload = try credentials()
        payload.fields[0].value = "key-\"quoted\"\nsecond line"
        let reply = try CourierFixtures.object(payload.replyContent())
        XCTAssertEqual(reply, [
            "app_key": "key-\"quoted\"\nsecond line",
            "nonce": nonce,
            "rendezvous_relay": relay,
        ])
        XCTAssertEqual(payload.replyTags, [["e", requestId]])
    }

    func testCanSendNeedsOneFilledField() throws {
        var payload = try credentials()
        XCTAssertFalse(payload.canSend)
        payload.fields[1].value = "s3cr3t"
        XCTAssertTrue(payload.canSend)
    }

    func testAFieldThatBreaksItsRuleBlocksSending() throws {
        let form = try CourierFixtures.text("credential_form") {
            CourierFixtures.set(&$0, property: "secret", "minLength", 8)
        }
        var payload = try XCTUnwrap(CourierPayload.parse(tags: [["form", form]], requestId: requestId))
        payload.fields[1].value = "short"
        XCTAssertEqual(payload.problems, ["secret": "At least 8 characters"])
        XCTAssertFalse(payload.canSend)
        payload.fields[1].value = "long enough"
        XCTAssertTrue(payload.canSend)
    }

    func testApprovedFillsOnlyFieldsWithoutChoices() throws {
        let payload = try XCTUnwrap(CourierPayload.parse(
            tags: [["form", try CourierFixtures.text("approval")]], requestId: requestId
        )).approved()
        XCTAssertEqual(payload.fields.map(\.value), ["approved", "2h"])
    }

    // MARK: - Recognising courier traffic

    func testReplyFieldCountReadsOurOwnReply() throws {
        var payload = try credentials()
        payload.fields[0].value = "k"
        payload.fields[1].value = "s"
        XCTAssertEqual(CourierPayload.replyFieldCount(payload.replyContent()), 2)
        XCTAssertNil(CourierPayload.replyFieldCount("hello"))
        XCTAssertNil(CourierPayload.replyFieldCount(#"{"note":"no nonce"}"#))
        XCTAssertNil(CourierPayload.replyFieldCount(#"{"nonce":5}"#))
    }

    func testCourierTrafficIsRecognised() throws {
        XCTAssertTrue(CourierPayload.isCourierTraffic(content: "Hi", tags: [["form", "{}"]]))
        XCTAssertTrue(CourierPayload.isCourierTraffic(content: #"{"nonce":"x","secret":"y"}"#, tags: []))
        XCTAssertTrue(CourierPayload.isCourierTraffic(content: "  secret = @@@x@@@", tags: []))
        XCTAssertFalse(CourierPayload.isCourierTraffic(content: "see you at 5", tags: []))
    }

    // MARK: - The text twin of a request

    private let twinBody = """
    Hi — excalibur-mcp needs to verify you own this npub.
    --- Credential Payload ---
      confirm = @@@PASTE_YOUR_CONFIRM_HERE@@@
      cache_duration = @@@2h@@@
      nonce = @@@bold-hawk-42@@@
      rendezvous_relay = @@@wss://relay.example@@@
    """

    func testTwinNonceReadsTheBodysNonceLine() {
        XCTAssertEqual(CourierPayload.twinNonce(content: twinBody), nonce)
        XCTAssertNil(CourierPayload.twinNonce(content: "nonce = bold-hawk-42"))
        XCTAssertNil(CourierPayload.twinNonce(content: "nonce = @@@@@@"))
        XCTAssertNil(CourierPayload.twinNonce(content: "see you at 5"))
        XCTAssertEqual(CourierPayload.twinNonce(content: "nonce = ##x##", delimiter: "##"), "x")
    }

    func testOnlyATaglessCopyIsATextTwin() throws {
        XCTAssertEqual(CourierPayload.textTwinNonce(content: twinBody, tags: [["p", "aa"]]), nonce)
        let formTags = [["p", "aa"], ["form", try CourierFixtures.text("credential_form")]]
        XCTAssertNil(CourierPayload.textTwinNonce(content: twinBody, tags: formTags))
        XCTAssertEqual(CourierPayload.formNonce(tags: formTags), try credentials().nonce)
        XCTAssertNil(CourierPayload.formNonce(tags: [["p", "aa"]]))
    }
}
