import UserNotifications
import XCTest
@testable import PricingStudioCore

final class ProofApprovalServiceTests: XCTestCase {

    private let token = "bold-hawk-42"
    private let relay = "wss://relay.example"
    private let requestId = String(repeating: "c", count: 64)

    private func tags(_ fixture: String) throws -> [[String]] {
        [["p", "aa"], ["form", try CourierFixtures.text(fixture)]]
    }

    // MARK: - Classifier

    func testClassifiesTheProofApproval() throws {
        let challenge = try XCTUnwrap(
            ProofApprovalService.classify(tags: try tags("approval"), requestId: requestId)
        )
        XCTAssertEqual(challenge.nonce, token)
        XCTAssertEqual(challenge.pinnedRelay, URL(string: relay))
    }

    func testCredentialFormIsNotOneTap() throws {
        XCTAssertNil(ProofApprovalService.classify(tags: try tags("credential_form"), requestId: requestId))
    }

    func testApprovalAskingForASecretIsNotOneTap() throws {
        let form = try CourierFixtures.text("approval") {
            CourierFixtures.set(&$0, property: "confirm", "writeOnly", true)
        }
        XCTAssertNil(ProofApprovalService.classify(tags: [["form", form]], requestId: requestId))
    }

    func testAPeerGrantIsNeverOneTap() throws {
        // It lets another npub watch the account; only the in-app form shows who.
        XCTAssertNil(ProofApprovalService.classify(tags: try tags("peer_grant"), requestId: requestId))
    }

    func testThePeerGrantFormNamesThePeer() throws {
        let form = try XCTUnwrap(CourierForm.parse(try CourierFixtures.text("peer_grant")))
        XCTAssertEqual(form.peerNpub, "npub1d999638gqpn8c594teklxtxva0uvxdng80q3ycyqvldjdl457c7qcrq64z")
        XCTAssertTrue(form.isPeerGrant)
        XCTAssertEqual(form.kind, .approval)
        XCTAssertNotNil(form.property("allow_for"))
        XCTAssertFalse(try XCTUnwrap(CourierForm.parse(try CourierFixtures.text("approval"))).isPeerGrant)
    }

    func testAMalformedPeerIsNoPeer() throws {
        for bad in ["npub1short", "nsec1" + String(repeating: "q", count: 58), "npub1" + String(repeating: "b", count: 58)] {
            let text = try CourierFixtures.text("peer_grant") { $0["x-peer-npub"] = bad }
            XCTAssertNil(try XCTUnwrap(CourierForm.parse(text)).peerNpub, bad)
        }
    }

    func testTextOnlyMessageIsNotAChallenge() {
        XCTAssertNil(ProofApprovalService.classify(tags: [["p", "aa"]], requestId: requestId))
    }

    // MARK: - Reply Builder

    func testApprovalReplyIsJSONWithNonceRelayAndDuration() throws {
        let challenge = try XCTUnwrap(
            ProofApprovalService.classify(tags: try tags("approval"), requestId: requestId)
        )
        let reply = try CourierFixtures.object(ProofApprovalService.buildApprovalReply(challenge))
        XCTAssertEqual(reply, [
            "confirm": "approved",
            "cache_duration": "2h",
            "nonce": token,
            "rendezvous_relay": relay,
        ])
    }

    func testApprovalReplyDurationPassthrough() throws {
        let challenge = try XCTUnwrap(
            ProofApprovalService.classify(tags: try tags("approval"), requestId: requestId)
        )
        let reply = try CourierFixtures.object(
            ProofApprovalService.buildApprovalReply(challenge, duration: "30d")
        )
        XCTAssertEqual(reply["cache_duration"], "30d")
    }

    // MARK: - userInfo Codec

    func testApprovalRequestRoundTrip() {
        let request = ProofApprovalService.ApprovalRequest(
            signerNpub: "npub1patron",
            replyToHex: String(repeating: "a", count: 64),
            pinnedRelay: URL(string: relay)!,
            replyContent: #"{"nonce":"faint-dusk-55"}"#,
            eventId: String(repeating: "e", count: 64),
            requestId: String(repeating: "f", count: 64)
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
            eventId: "ee",
            requestId: "ff"
        )

        var missingKey = request.userInfo
        missingKey.removeValue(forKey: "proofApproval.replyContent")
        XCTAssertNil(ProofApprovalService.ApprovalRequest(userInfo: missingKey))

        var noRequestId = request.userInfo
        noRequestId.removeValue(forKey: "proofApproval.requestId")
        XCTAssertNil(ProofApprovalService.ApprovalRequest(userInfo: noRequestId))

        var wrongVersion = request.userInfo
        wrongVersion["proofApproval.v"] = 1
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
    /// nonce must never appear in the identifier — it is SHA-256 digested.
    /// (The DMPollingService integration — that its notification content wires this
    /// in — stays a hosted test; this covers the extractable hashing directly.)
    func testApprovalThreadIdentifierIsPerTokenNonEmptyAndHashed() {
        let a = ProofApprovalService.approvalThreadIdentifier(nonce: "tok-a")
        let b = ProofApprovalService.approvalThreadIdentifier(nonce: "tok-b")

        XCTAssertFalse(a.isEmpty, "Approval banner must declare its own notification group")
        XCTAssertNotEqual(a, b, "Distinct approvals stay in distinct groups")
        XCTAssertTrue(a.hasPrefix(ProofApprovalService.categoryId),
                      "Thread stays scoped to the approval category")
        XCTAssertFalse(a.contains("tok-a"),
                       "Raw nonce must not leak into threadIdentifier (SHA-256 digested)")
    }
}
