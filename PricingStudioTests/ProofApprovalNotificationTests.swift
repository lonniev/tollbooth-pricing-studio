import PricingStudioCore
import UserNotifications
import XCTest
@testable import PricingStudio

/// Hosted companions to `PricingStudioCoreTests/ProofApprovalServiceTests`.
/// These exercise `DMPollingService`'s notification-content builders (app code,
/// not extractable to PricingStudioCore), verifying they wire the package's
/// per-token thread isolation into real `UNNotificationContent`. The pure
/// hashing/classification logic is covered host-free in the package tests;
/// this covers the app-side integration (issue #83).
@MainActor
final class ProofApprovalNotificationTests: XCTestCase {

    private let token = "faint-dusk-55"
    private let relay = "wss://relay.primal.net"

    private func approvalRequest() -> ProofApprovalService.ApprovalRequest {
        ProofApprovalService.ApprovalRequest(
            signerNpub: "npub1patron",
            replyToHex: String(repeating: "a", count: 64),
            pinnedRelay: URL(string: relay)!,
            replyContent: "Approved.",
            eventId: String(repeating: "e", count: 64)
        )
    }

    /// Regression for #83. On Apple Watch, dismissing one delivered
    /// notification purges every notification sharing its group, and banners
    /// group by `threadIdentifier`. An unset identifier lands every banner in
    /// the app's single default group — so dismissing a Nostr DM banner swept
    /// away the actionable Approval Request with it. The two banner kinds must
    /// carry DIFFERENT, non-empty thread identifiers.
    func testApprovalAndDMBannersUseDistinctNonEmptyThreads() {
        let approval = DMPollingService.makeApprovalNotificationContent(
            body: "May I act as bob? — from alice",
            request: approvalRequest(),
            dpopToken: token
        )
        let dm = DMPollingService.makeDMNotificationContent(
            senderName: "alice", receiverName: "bob", preview: "hi"
        )

        XCTAssertFalse(approval.threadIdentifier.isEmpty,
                       "Approval banner must declare its own notification group")
        XCTAssertFalse(dm.threadIdentifier.isEmpty,
                       "DM banner must declare its own notification group")
        XCTAssertNotEqual(approval.threadIdentifier, dm.threadIdentifier,
                          "Dismissing a DM must not sweep away an Approval Request (#83)")
    }

    /// Distinct approvals stay in distinct groups, so dismissing one actionable
    /// request never clears another sibling approval.
    func testEachApprovalGetsItsOwnThread() {
        let a = DMPollingService.makeApprovalNotificationContent(
            body: "x", request: approvalRequest(), dpopToken: "tok-a")
        let b = DMPollingService.makeApprovalNotificationContent(
            body: "y", request: approvalRequest(), dpopToken: "tok-b")
        XCTAssertNotEqual(a.threadIdentifier, b.threadIdentifier)
    }

    /// Isolating the thread must not strip the approval's actionable category
    /// or its precomputed userInfo payload.
    func testApprovalContentStaysActionable() {
        let content = DMPollingService.makeApprovalNotificationContent(
            body: "b", request: approvalRequest(), dpopToken: token)
        XCTAssertEqual(content.categoryIdentifier, ProofApprovalService.categoryId)
        XCTAssertNotNil(ProofApprovalService.ApprovalRequest(userInfo: content.userInfo),
                        "The action handler still needs the precomputed reply payload")
    }
}
