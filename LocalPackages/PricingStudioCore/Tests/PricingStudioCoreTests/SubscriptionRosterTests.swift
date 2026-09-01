import XCTest
@testable import PricingStudioCore

/// Protects the mid-session subscription reconciliation that keeps live
/// Nostr DM subscriptions in lock-step with the Operator/Patron/Authority
/// roster (issue #148).
///
/// Before the fix, `startSubscriptions` ran once at launch and the poll loop
/// never called `subscribe` for npubs added later — while still short-circuiting
/// the relay-fetch fallback whenever `subscriptionsActive` was true. A newly
/// adopted Operator's DMs were therefore invisible until Pricing Studio
/// restarted. These tests pin the pure diff that drives the per-cycle reconcile.
final class SubscriptionRosterTests: XCTestCase {

    // MARK: - Issue #148: mid-session adoption

    /// The defect: roster grows after launch, subscription set does not.
    /// Diff must report the new npub as needing subscribe.
    func testNewlyAddedNpubNeedsSubscribe() {
        let diff = SubscriptionRoster.diff(
            roster: ["npub1old", "npub1new"],
            subscribed: ["npub1old"]
        )
        XCTAssertEqual(diff.toSubscribe, ["npub1new"])
        XCTAssertTrue(diff.toUnsubscribe.isEmpty)
    }

    /// First keyed entity ever (launch had an empty roster) must still
    /// produce a subscribe — connections come up on demand in reconcile.
    func testEmptySubscriptionsGainsEntireRoster() {
        let diff = SubscriptionRoster.diff(
            roster: ["npub1a", "npub1b"],
            subscribed: []
        )
        XCTAssertEqual(diff.toSubscribe, ["npub1a", "npub1b"])
        XCTAssertTrue(diff.toUnsubscribe.isEmpty)
    }

    // MARK: - Idempotency across many poll cycles

    /// When roster and subscription set already match, every subsequent cycle
    /// is a no-op — `subscribe` must not be re-entered (manager is idempotent,
    /// but the reconcile path should not even ask).
    func testMatchedSetsProduceEmptyDiff() {
        let npubs: Set<String> = ["npub1a", "npub1b", "npub1c"]
        let diff = SubscriptionRoster.diff(roster: npubs, subscribed: npubs)
        XCTAssertTrue(diff.toSubscribe.isEmpty)
        XCTAssertTrue(diff.toUnsubscribe.isEmpty)
    }

    func testRepeatedDiffAgainstStableSetsStaysEmpty() {
        let roster: Set<String> = ["npub1a", "npub1b"]
        let subscribed: Set<String> = ["npub1a", "npub1b"]
        for _ in 0..<50 {
            let diff = SubscriptionRoster.diff(roster: roster, subscribed: subscribed)
            XCTAssertTrue(diff.toSubscribe.isEmpty)
            XCTAssertTrue(diff.toUnsubscribe.isEmpty)
        }
    }

    // MARK: - Removals

    /// An identity removed from the roster (deleted Operator, etc.) must drop
    /// its subscription so it stops consuming a relay filter slot.
    func testRemovedNpubNeedsUnsubscribe() {
        let diff = SubscriptionRoster.diff(
            roster: ["npub1kept"],
            subscribed: ["npub1kept", "npub1gone"]
        )
        XCTAssertTrue(diff.toSubscribe.isEmpty)
        XCTAssertEqual(diff.toUnsubscribe, ["npub1gone"])
    }

    /// Simultaneous add + remove (replace one Operator with another).
    func testSimultaneousAddAndRemove() {
        let diff = SubscriptionRoster.diff(
            roster: ["npub1kept", "npub1new"],
            subscribed: ["npub1kept", "npub1old"]
        )
        XCTAssertEqual(diff.toSubscribe, ["npub1new"])
        XCTAssertEqual(diff.toUnsubscribe, ["npub1old"])
    }

    // MARK: - Empty edges

    func testEmptyRosterUnsubscribesEverything() {
        let diff = SubscriptionRoster.diff(
            roster: [],
            subscribed: ["npub1a", "npub1b"]
        )
        XCTAssertTrue(diff.toSubscribe.isEmpty)
        XCTAssertEqual(diff.toUnsubscribe, ["npub1a", "npub1b"])
    }

    func testBothEmptyIsNoOp() {
        let diff = SubscriptionRoster.diff(roster: [], subscribed: [])
        XCTAssertTrue(diff.toSubscribe.isEmpty)
        XCTAssertTrue(diff.toUnsubscribe.isEmpty)
    }
}
