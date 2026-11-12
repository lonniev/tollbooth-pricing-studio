import DPYCAuthKit
import XCTest
@testable import PricingStudio

/// The courier sends each request as a form and as a text copy. Studio shows
/// the form, whichever copy arrives first.
final class DMConversationDedupTests: XCTestCase {

    private let sender = String(repeating: "a", count: 64)
    private let me = String(repeating: "b", count: 64)
    private let nonce = "neat-zero-14"
    private let start = Date(timeIntervalSince1970: 1_794_429_096)

    private var formTag: [String] {
        let form: [String: Any] = [
            "type": "object",
            "properties": [
                "confirm": ["type": "string", "title": "confirm", "propertyOrder": 1],
                "nonce": ["type": "string", "const": nonce, "readOnly": true],
                "rendezvous_relay": ["type": "string", "const": "wss://relay.snort.social", "readOnly": true],
            ],
            "required": ["confirm", "nonce", "rendezvous_relay"],
            "x-delimiter": "@@@",
            "x-courier-kind": "approval",
            "x-service": "npub_ownership",
        ]
        let data = try! JSONSerialization.data(withJSONObject: form)
        return ["form", String(decoding: data, as: UTF8.self)]
    }

    private var body: String {
        """
        Hi — excalibur-mcp needs to verify you own this npub.
        --- Credential Payload ---
          confirm = @@@PASTE_YOUR_CONFIRM_HERE@@@
          nonce = @@@\(nonce)@@@
          rendezvous_relay = @@@wss://relay.snort.social@@@
        """
    }

    private func form(at offset: TimeInterval = 0) -> DecryptedDM {
        DecryptedDM(rawEventId: "form", senderPubkeyHex: sender, recipientPubkeyHex: me,
                    content: body, createdAt: start.addingTimeInterval(offset),
                    encryption: .nip44, isFromMe: false, tags: [["p", me], formTag])
    }

    private func text(at offset: TimeInterval = 0, content: String? = nil) -> DecryptedDM {
        DecryptedDM(rawEventId: "text", senderPubkeyHex: sender, recipientPubkeyHex: me,
                    content: content ?? body, createdAt: start.addingTimeInterval(offset),
                    encryption: .nip04, isFromMe: false, tags: [["p", me], ["expiration", "1"]])
    }

    func testTheFormIsShownWhicheverCopyArrivesFirst() {
        for messages in [[form(), text(at: 1)], [text(), form(at: 1)], [text(at: -5, content: body + "\n"), form()]] {
            let shown = DMConversation(counterpartyPubkeyHex: sender, messages: messages).dedupedMessages
            XCTAssertEqual(shown.map(\.rawEventId), ["form"])
        }
    }

    /// The live path: each copy arrives on its own and is absorbed in turn.
    /// The text copy landing first must not keep its form out (11-12: the
    /// form won the comparison and was then dropped).
    func testALiveFormReplacesItsTextCopyThatArrivedFirst() {
        var convo = DMConversation(counterpartyPubkeyHex: sender, messages: [])
        XCTAssertTrue(convo.absorb(text()).appended)
        XCTAssertFalse(convo.absorb(form(at: -1)).appended)
        XCTAssertEqual(convo.messages.map(\.rawEventId), ["form"])
        XCTAssertEqual(convo.dedupedMessages.map(\.rawEventId), ["form"])
    }

    func testALiveTextCopyNeverReplacesItsForm() {
        var convo = DMConversation(counterpartyPubkeyHex: sender, messages: [])
        convo.absorb(form())
        XCTAssertFalse(convo.absorb(text(at: 1)).appended)
        XCTAssertEqual(convo.messages.map(\.rawEventId), ["form"])
    }

    func testAbsorbIgnoresTheSameEventTwiceAndReplacesAnOptimisticSend() {
        var convo = DMConversation(counterpartyPubkeyHex: sender, messages: [])
        convo.absorb(form())
        XCTAssertFalse(convo.absorb(form()).appended)
        XCTAssertEqual(convo.messages.count, 1)

        let optimistic = DecryptedDM(rawEventId: "local-1", senderPubkeyHex: me, recipientPubkeyHex: sender,
                                     content: "hello", createdAt: start, encryption: .nip44, isFromMe: true, tags: [])
        let echo = DecryptedDM(rawEventId: "relay-1", senderPubkeyHex: me, recipientPubkeyHex: sender,
                               content: "hello", createdAt: start.addingTimeInterval(2), encryption: .nip44,
                               isFromMe: true, tags: [])
        convo.absorb(optimistic)
        let result = convo.absorb(echo, pendingIds: ["local-1"])
        XCTAssertEqual(result.replacedPendingId, "local-1")
        XCTAssertFalse(result.appended)
        XCTAssertEqual(convo.messages.map(\.rawEventId), ["form", "relay-1"])
    }

    func testATextCopyWithoutItsFormStays() {
        let shown = DMConversation(counterpartyPubkeyHex: sender, messages: [text()]).dedupedMessages
        XCTAssertEqual(shown.map(\.rawEventId), ["text"])
    }

    func testLiveMergeKeepsTheForm() {
        XCTAssertTrue(DMConversation.isCopy(text(at: 2), of: form()))
        XCTAssertTrue(DMConversation.isCopy(form(), of: text(at: 2)))
        XCTAssertFalse(DMConversation.prefers(text(at: 2), over: form()), "a later text copy never replaces the form")
        XCTAssertTrue(DMConversation.prefers(form(), over: text(at: 2)), "a form replaces its text copy")
    }

    func testAnotherRequestIsNotACopy() {
        let other = text(content: body.replacingOccurrences(of: nonce, with: "bold-hawk-42"))
        XCTAssertFalse(DMConversation.isCopy(other, of: form()))
        let shown = DMConversation(counterpartyPubkeyHex: sender, messages: [form(), other]).dedupedMessages
        XCTAssertEqual(Set(shown.map(\.rawEventId)), ["form", "text"])
    }
}
