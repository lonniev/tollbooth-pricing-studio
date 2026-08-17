import UserNotifications
import XCTest
@testable import PricingStudioCore

final class ProofApprovalServiceTests: XCTestCase {

    private let token = "faint-dusk-55"
    private let relay = "wss://relay.primal.net"

    /// Mirrors the wheel's build_welcome output for the npub-ownership proof
    /// template (nostr_credentials.py build_welcome + runtime.py proof
    /// template: confirm placeholder, cache_duration prefilled "2h").
    private func challengeDM(
        confirmLine: String = "  confirm = @@@PASTE_YOUR_CONFIRM_HERE@@@",
        tokenLine: String? = nil,
        relayLine: String? = nil
    ) -> String {
        """
        A service wants to verify you own this npub.

        --- Credential Payload ---
        \(confirmLine)
          cache_duration = @@@2h@@@
        \(tokenLine ?? "  dpop_token = @@@\(token)@@@")
        \(relayLine ?? "  rendezvous_relay = @@@\(relay)@@@")

        IMPORTANT: include the anti-replay token exactly as shown.
        IMPORTANT: reply via the rendezvous_relay above — the courier listens there.

        --- Message Provenance ---
        Service: Npub ownership — the signed DM itself proves you own this npub
        Operator: npub1operator
        Sent: 2026-07-04 12:00:00 UTC
        Protocol: DPYC Secure Courier v0.59.1

        Your reply is end-to-end encrypted — only this service can read it.
        If you didn't request this, simply ignore this message.
        """
    }

    // MARK: - Classifier

    func testClassifiesWheelProofChallenge() {
        let challenge = ProofApprovalService.classify(challengeDM())

        XCTAssertNotNil(challenge)
        XCTAssertEqual(challenge?.dpopToken, token)
        XCTAssertEqual(challenge?.pinnedRelay.absoluteString, relay)
        XCTAssertEqual(challenge?.confirmKey, "confirm")
    }

    func testClassifiesChallengeWithPrefilledConfirm() {
        // Operator gave the confirm field a default — nothing needs input.
        let dm = challengeDM(confirmLine: "  confirm = @@@yes@@@")
        let challenge = ProofApprovalService.classify(dm)

        XCTAssertNotNil(challenge)
        XCTAssertNil(challenge?.confirmKey)
    }

    func testRejectsCredentialChannelDM() {
        // A credential channel asks for real secrets — never one-tap approvable.
        let dm = """
        Welcome! Reply with your credentials.

        --- Credential Payload ---
          api_key = @@@PASTE_YOUR_API_KEY_HERE@@@
          api_secret = @@@PASTE_YOUR_API_SECRET_HERE@@@
          dpop_token = @@@\(token)@@@
          rendezvous_relay = @@@\(relay)@@@
        """
        XCTAssertNil(ProofApprovalService.classify(dm))
    }

    func testRejectsPassphraseProofField() {
        // taxsort's proof field stores the supplied value as a passphrase —
        // a watch tap must not silently set one.
        let dm = challengeDM(confirmLine: "  passphrase = @@@PASTE_YOUR_PASSPHRASE_HERE@@@")
        XCTAssertNil(ProofApprovalService.classify(dm))
    }

    func testRejectsMalformedChallenges() {
        XCTAssertNil(ProofApprovalService.classify(challengeDM(tokenLine: "  ")),
                     "Missing dpop_token")
        XCTAssertNil(ProofApprovalService.classify(challengeDM(relayLine: "  ")),
                     "Missing rendezvous_relay")
        XCTAssertNil(ProofApprovalService.classify(
            challengeDM(relayLine: "  rendezvous_relay = @@@https://example.com@@@")),
            "Non-websocket relay")
        XCTAssertNil(ProofApprovalService.classify("Just a friendly plain-text DM"),
                     "No courier fields")
    }

    // MARK: - Reply Builder

    func testApprovalReplyEchoesTokenAndDuration() {
        let challenge = ProofApprovalService.classify(challengeDM())!
        let reply = ProofApprovalService.buildApprovalReply(challenge)

        XCTAssertTrue(reply.contains("dpop_token = @@@\(token)@@@"), "Token must echo exactly")
        XCTAssertTrue(reply.contains("cache_duration = @@@2h@@@"))
        XCTAssertTrue(reply.contains("confirm = @@@approved@@@"))
        XCTAssertFalse(reply.contains("rendezvous_relay"), "Control field never echoes")
        XCTAssertFalse(reply.contains("PASTE_YOUR"), "No placeholders survive")

        // The operator parses the reply with the same field grammar.
        let reparsed = CourierPayload.parse(reply)
        XCTAssertEqual(reparsed?.poison?.value, token)
    }

    func testApprovalReplyDurationPassthrough() {
        let challenge = ProofApprovalService.classify(challengeDM())!

        XCTAssertTrue(ProofApprovalService.buildApprovalReply(challenge, duration: "30 min")
            .contains("cache_duration = @@@30 min@@@"))
        XCTAssertTrue(ProofApprovalService.buildApprovalReply(challenge, duration: "unlimited")
            .contains("cache_duration = @@@unlimited@@@"))
    }

    // MARK: - userInfo Codec

    func testApprovalRequestRoundTrip() {
        let request = ProofApprovalService.ApprovalRequest(
            signerNpub: "npub1patron",
            replyToHex: String(repeating: "a", count: 64),
            pinnedRelay: URL(string: relay)!,
            replyContent: "Approved.\n\n  dpop_token = @@@\(token)@@@",
            eventId: String(repeating: "e", count: 64)
        )

        let decoded = ProofApprovalService.ApprovalRequest(userInfo: request.userInfo)
        XCTAssertEqual(decoded, request)
    }

    func testApprovalRequestDecodeRejectsBadInput() {
        let request = ProofApprovalService.ApprovalRequest(
            signerNpub: "npub1patron",
            replyToHex: "aa",
            pinnedRelay: URL(string: relay)!,
            replyContent: "x",
            eventId: "ee"
        )

        var missingKey = request.userInfo
        missingKey.removeValue(forKey: "proofApproval.replyContent")
        XCTAssertNil(ProofApprovalService.ApprovalRequest(userInfo: missingKey))

        var wrongVersion = request.userInfo
        wrongVersion["proofApproval.v"] = 2
        XCTAssertNil(ProofApprovalService.ApprovalRequest(userInfo: wrongVersion))

        XCTAssertNil(ProofApprovalService.ApprovalRequest(userInfo: [:]))
    }

    // MARK: - Category Shape

    func testCategoryShape() {
        let category = ProofApprovalService.makeCategory()

        XCTAssertEqual(category.identifier, "courier-proof-approval")
        XCTAssertEqual(category.actions.map(\.identifier), ["approve", "reject"])
        XCTAssertTrue(category.options.contains(.customDismissAction))

        let approve = category.actions[0]
        XCTAssertTrue(
            approve.options.contains(.authenticationRequired),
            "Approve requires unlock (CourierBridgeDoctrine.acceptRequiresUnlock / #139)"
        )
        XCTAssertFalse(
            approve.options.contains(.foreground),
            "Approve still completes in background after unlock — no full app launch required"
        )
        XCTAssertTrue(category.actions[1].options.contains(.destructive))
        XCTAssertFalse(
            category.actions[1].options.contains(.authenticationRequired),
            "Reject may complete while locked (CourierBridgeDoctrine.rejectWhileLocked)"
        )
    }

    // MARK: - Watch Notification Thread Isolation (issue #83 — core hashing logic)

    /// Regression for #83, host-free. Banners group by `threadIdentifier`, and
    /// on Apple Watch dismissing one member purges the whole group. Each approval
    /// must get its OWN non-empty, category-scoped thread so dismissing a DM (or a
    /// sibling approval) never sweeps away an actionable Approval Request. The raw
    /// dpop_token must never appear in the identifier — it is SHA-256 digested.
    /// (The DMPollingService integration — that its notification content wires this
    /// in — stays a hosted test; this covers the extractable hashing directly.)
    func testApprovalThreadIdentifierIsPerTokenNonEmptyAndHashed() {
        let a = ProofApprovalService.approvalThreadIdentifier(dpopToken: "tok-a")
        let b = ProofApprovalService.approvalThreadIdentifier(dpopToken: "tok-b")

        XCTAssertFalse(a.isEmpty, "Approval banner must declare its own notification group")
        XCTAssertNotEqual(a, b, "Distinct approvals stay in distinct groups")
        XCTAssertTrue(a.hasPrefix(ProofApprovalService.categoryId),
                      "Thread stays scoped to the approval category")
        XCTAssertFalse(a.contains("tok-a"),
                       "Raw dpop_token must not leak into threadIdentifier (SHA-256 digested)")
    }
}
