import XCTest
@testable import PricingStudio

final class CourierPayloadTests: XCTestCase {

    // MARK: - Parse Nil on Plain Text

    func testParseNilOnPlainText() {
        XCTAssertNil(CourierPayload.parse("Hello, this is a regular message."))
        XCTAssertNil(CourierPayload.parse(""))
        XCTAssertNil(CourierPayload.parse("No delimiters here @ at all"))
    }

    // MARK: - Parse Basic Fields

    func testParseBasicFields() {
        let text = "nsec = @@@nsec1abc123@@@\nclaim = @@@yes@@@"
        let payload = CourierPayload.parse(text)

        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.fields.count, 2)
        XCTAssertEqual(payload?.fields[0].key, "nsec")
        XCTAssertEqual(payload?.fields[0].value, "nsec1abc123")
        XCTAssertEqual(payload?.fields[1].key, "claim")
        XCTAssertEqual(payload?.fields[1].value, "yes")
    }

    // MARK: - Parse Full Welcome DM

    func testParseFullWelcomeDM() {
        let text = """
        Welcome to the Tollbooth network!

        Please fill in your credentials below.

        --- Credential Payload ---
          nsec = @@@PASTE_YOUR_NSEC_HERE@@@
          claim = @@@PASTE_YOUR_CLAIM_HERE@@@
          poison = @@@7f3a2b1c@@@

        --- Message Provenance ---
        Service: tollbooth-authority
        Operator: npub1exampleoperator123
        Sent: 2026-03-15T10:00:00Z
        Protocol: secure-courier/1.0
        """

        let payload = CourierPayload.parse(text)

        XCTAssertNotNil(payload)
        XCTAssertTrue(payload!.greeting.contains("Welcome to the Tollbooth"))
        XCTAssertEqual(payload!.fields.count, 2)
        XCTAssertNotNil(payload!.poison)
        XCTAssertEqual(payload!.poison?.key, "poison")
        XCTAssertEqual(payload!.poison?.value, "7f3a2b1c")
        XCTAssertEqual(payload!.provenance.service, "tollbooth-authority")
        XCTAssertEqual(payload!.provenance.operatorNpub, "npub1exampleoperator123")
        XCTAssertEqual(payload!.provenance.sent, "2026-03-15T10:00:00Z")
        XCTAssertEqual(payload!.provenance.protocolVersion, "secure-courier/1.0")
    }

    // MARK: - Placeholder Detection

    func testPlaceholderDetection() {
        let text = "nsec = @@@PASTE_YOUR_NSEC_HERE@@@\nclaim = @@@PASTE_YOUR_CLAIM_HERE@@@"
        let payload = CourierPayload.parse(text)!

        XCTAssertTrue(payload.fields[0].needsInput)
        XCTAssertTrue(payload.fields[1].needsInput)
    }

    // MARK: - Filled Fields Not Placeholders

    func testFilledFieldsNotPlaceholders() {
        let text = "nsec = @@@nsec1realkey@@@\nclaim = @@@yes@@@"
        let payload = CourierPayload.parse(text)!

        XCTAssertFalse(payload.fields[0].needsInput)
        XCTAssertFalse(payload.fields[1].needsInput)
    }

    // MARK: - Poison Separated

    func testPoisonSeparated() {
        let text = "nsec = @@@val@@@\npoison = @@@deadbeef@@@\nclaim = @@@yes@@@"
        let payload = CourierPayload.parse(text)!

        XCTAssertEqual(payload.fields.count, 2, "Poison should not be in fields")
        XCTAssertNotNil(payload.poison)
        XCTAssertEqual(payload.poison?.value, "deadbeef")
        XCTAssertTrue(payload.fields.allSatisfy { $0.key != "poison" })
    }

    // MARK: - isComplete When All Filled

    func testIsCompleteWhenAllFilled() {
        let text = "nsec = @@@nsec1real@@@\nclaim = @@@yes@@@"
        let payload = CourierPayload.parse(text)!
        XCTAssertTrue(payload.isComplete)
    }

    func testIsNotCompleteWithPlaceholders() {
        let text = "nsec = @@@PASTE_YOUR_NSEC_HERE@@@\nclaim = @@@yes@@@"
        let payload = CourierPayload.parse(text)!
        XCTAssertFalse(payload.isComplete)
    }

    // MARK: - Newline Stripping

    func testNewlineStripping() {
        let text = "nsec = @@@nsec1abc\n123\r\n456@@@"
        let payload = CourierPayload.parse(text)!

        XCTAssertEqual(payload.fields[0].value, "nsec1abc123456",
                       "Newlines injected by mobile clients should be stripped")
    }

    // MARK: - Serialize Round Trip

    func testSerializeRoundTrip() {
        let text = """
        --- Credential Payload ---
          nsec = @@@nsec1abc@@@
          claim = @@@yes@@@
          poison = @@@deadbeef@@@
        """

        var payload = CourierPayload.parse(text)!

        // Edit a field
        payload.fields[0].value = "nsec1edited"

        let serialized = payload.serialize()

        XCTAssertTrue(serialized.contains("nsec = @@@nsec1edited@@@"))
        XCTAssertTrue(serialized.contains("claim = @@@yes@@@"))
        XCTAssertTrue(serialized.contains("poison = @@@deadbeef@@@"))

        // Re-parse the serialized output
        let reparsed = CourierPayload.parse(serialized)
        XCTAssertNotNil(reparsed)
        XCTAssertEqual(reparsed?.fields.first(where: { $0.key == "nsec" })?.value, "nsec1edited")
    }

    // MARK: - Provenance Parsing

    func testProvenanceParsing() {
        let text = """
        key = @@@val@@@

        --- Message Provenance ---
        Service: my-service
        Operator: npub1operator
        Sent: 2026-03-15T12:00:00Z
        Protocol: secure-courier/2.0
        """

        let payload = CourierPayload.parse(text)!

        XCTAssertEqual(payload.provenance.service, "my-service")
        XCTAssertEqual(payload.provenance.operatorNpub, "npub1operator")
        XCTAssertEqual(payload.provenance.sent, "2026-03-15T12:00:00Z")
        XCTAssertEqual(payload.provenance.protocolVersion, "secure-courier/2.0")
    }

    // MARK: - Greeting Fields Not Duplicated

    func testGreetingFieldsNotDuplicated() {
        // The challenge DM has @@@yes@@@ in the instruction text AND in the payload section.
        // Only the payload section fields should be extracted.
        let text = """
        You are requesting to become the curator of this Authority. Reply with: claim = @@@yes@@@ and include the poison slug.

        --- Credential Payload ---
          claim = @@@yes@@@
          poison = @@@keen-nest-44@@@

        --- Message Provenance ---
        Service: tollbooth-authority
        Operator: npub1example
        Sent: 2026-03-20T16:00:00Z
        Protocol: secure-courier/1.0
        """

        let payload = CourierPayload.parse(text)!

        XCTAssertEqual(payload.fields.count, 1, "Only one 'claim' field from the payload section, not the greeting")
        XCTAssertEqual(payload.fields[0].key, "claim")
        XCTAssertEqual(payload.fields[0].value, "yes")
        XCTAssertNotNil(payload.poison)
        XCTAssertEqual(payload.poison?.value, "keen-nest-44")
        XCTAssertTrue(payload.greeting.contains("Reply with"))
    }

    // MARK: - Editing Placeholder Clears needsInput

    func testEditingPlaceholderClearsNeedsInput() {
        let text = """
        --- Credential Payload ---
          nsec = @@@PASTE_YOUR_NSEC_HERE@@@
          claim = @@@PASTE_YOUR_CLAIM_HERE@@@
        """
        var payload = CourierPayload.parse(text)!

        XCTAssertTrue(payload.fields[0].needsInput)
        XCTAssertTrue(payload.fields[1].needsInput)
        XCTAssertFalse(payload.isComplete)

        // Simulate user editing
        payload.fields[0].value = "nsec1realkey123"
        payload.fields[1].value = "yes"

        XCTAssertFalse(payload.fields[0].needsInput)
        XCTAssertFalse(payload.fields[1].needsInput)
        XCTAssertTrue(payload.isComplete)
    }

    // MARK: - No Fields Returns Nil

    func testNoFieldsReturnsNil() {
        let text = "@@@ some text @@@ but no key = pattern"
        XCTAssertNil(CourierPayload.parse(text))
    }

    // MARK: - Multiple @ Signs in Value

    func testMultipleAtSignsInValue() {
        let text = "email = @@@user@example.com@@@"
        let payload = CourierPayload.parse(text)

        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.fields.first?.value, "user@example.com")
    }

    func testAtSignsNotTripleInValue() {
        // Value containing @@ (double, not triple) should be captured correctly
        let text = "token = @@@abc@@def@@@"
        let payload = CourierPayload.parse(text)

        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.fields.first?.value, "abc@@def")
    }

    // MARK: - Rendezvous Relay Pin (v0.39.0+ protocol)

    func testRendezvousRelayExtracted() {
        // The wheel embeds the per-conversation rendezvous relay so the
        // responder knows where to publish their reply. Like ``poison``,
        // it's protocol-control metadata, not a user-editable field.
        let text = """
        --- Credential Payload ---
          nsec = @@@PASTE_YOUR_NSEC_HERE@@@
          poison = @@@bold-hawk-42@@@
          rendezvous_relay = @@@wss://relay.primal.net@@@
        """

        let payload = CourierPayload.parse(text)!

        XCTAssertEqual(payload.fields.count, 1, "Only nsec is user-editable")
        XCTAssertEqual(payload.fields[0].key, "nsec")
        XCTAssertEqual(payload.poison?.value, "bold-hawk-42")
        XCTAssertEqual(payload.rendezvousRelay?.value, "wss://relay.primal.net")
    }

    func testRendezvousRelayAbsentOnLegacyChallenge() {
        // Pre-v0.39.0 wheels don't embed rendezvous_relay. Parsing must
        // continue to succeed without it.
        let text = """
        --- Credential Payload ---
          nsec = @@@PASTE_YOUR_NSEC_HERE@@@
          poison = @@@bold-hawk-42@@@
        """

        let payload = CourierPayload.parse(text)!

        XCTAssertNotNil(payload.poison)
        XCTAssertNil(payload.rendezvousRelay)
    }

    func testRendezvousRelayNotSerializedInReply() {
        // The reply only needs to echo user-editable fields plus the
        // poison. The rendezvous URL is the sender's listener address
        // — it has no business in the reply body.
        let text = """
        --- Credential Payload ---
          nsec = @@@nsec1real@@@
          poison = @@@bold-hawk-42@@@
          rendezvous_relay = @@@wss://relay.primal.net@@@
        """

        let payload = CourierPayload.parse(text)!
        let serialized = payload.serialize()

        XCTAssertTrue(serialized.contains("nsec = @@@nsec1real@@@"))
        XCTAssertTrue(serialized.contains("poison = @@@bold-hawk-42@@@"))
        XCTAssertFalse(serialized.contains("rendezvous_relay"))
    }
}
