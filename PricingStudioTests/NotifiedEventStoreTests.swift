import XCTest
@testable import PricingStudio

/// Tests the durable per-npub seen-set that replaces the old 5-minute in-memory
/// notification dedup window.
///
/// These tests protect the notification protocol ONLY. They deliberately use an
/// isolated UserDefaults suite so nothing here touches the message-passing path
/// (decrypt / onLiveDM delivery / relay fetch), which lives upstream of this
/// store and is unaffected by it.
final class NotifiedEventStoreTests: XCTestCase {

    /// A throwaway UserDefaults so each test starts clean and never pollutes the
    /// app's real defaults.
    private func makeDefaults(_ fn: String = #function) -> UserDefaults {
        let suite = "test.notifiedstore.\(fn).\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private let npub = "npub1aaaaaaaaaaaaaaaaaaaaaaaa"

    // MARK: - Core dedup

    /// First sight of events returns them all; an immediate replay of the same
    /// events (relay redelivery) returns nothing — the bug's core symptom.
    func testFirstSightNotifies_ReplaySuppressed() {
        var store = NotifiedEventStore(defaults: makeDefaults())
        XCTAssertEqual(store.register(npub: npub, eventIds: ["e1", "e2"]), ["e1", "e2"])
        XCTAssertEqual(store.register(npub: npub, eventIds: ["e1", "e2"]), [])
    }

    /// A batch mixing already-seen and brand-new IDs notifies only for the new.
    func testMixedBatchReturnsOnlyFresh() {
        var store = NotifiedEventStore(defaults: makeDefaults())
        _ = store.register(npub: npub, eventIds: ["e1", "e2"])
        XCTAssertEqual(store.register(npub: npub, eventIds: ["e2", "e3", "e1", "e4"]), ["e3", "e4"])
    }

    /// Duplicates within a single batch collapse to one.
    func testIntraBatchDuplicatesCollapse() {
        var store = NotifiedEventStore(defaults: makeDefaults())
        XCTAssertEqual(store.register(npub: npub, eventIds: ["e1", "e1", "e1"]), ["e1"])
    }

    func testEmptyBatchIsNoOp() {
        var store = NotifiedEventStore(defaults: makeDefaults())
        XCTAssertEqual(store.register(npub: npub, eventIds: []), [])
    }

    // MARK: - Durability across processes (the relaunch / background-task hole)

    /// The old window was in-memory only, so every relaunch and every
    /// background-refresh process started empty and re-announced the backlog.
    /// A fresh store instance reading the same defaults must remember.
    func testPersistsAcrossInstances() {
        let defaults = makeDefaults()
        var first = NotifiedEventStore(defaults: defaults)
        XCTAssertEqual(first.register(npub: npub, eventIds: ["e1"]), ["e1"])

        // Simulate a brand-new process (app relaunch or BGAppRefreshTask).
        var second = NotifiedEventStore(defaults: defaults)
        XCTAssertTrue(second.contains(npub: npub, eventId: "e1"))
        XCTAssertEqual(second.register(npub: npub, eventIds: ["e1"]), [],
                       "a relaunched process must not re-announce an already-seen DM")
    }

    // MARK: - Permanent dedup (no forget-on-read)

    /// There is no forget-on-read path: once a banner has fired for an event, the
    /// ledger suppresses it forever (until oldest-eviction), even as the same event
    /// is replayed by relays across many poll cycles and across a relaunch. This is
    /// what stops a read-then-replayed DM from re-announcing — the leak that wiping
    /// the ledger on read used to open.
    func testAnnouncedEventStaysSuppressedAcrossReplays() {
        let defaults = makeDefaults()
        var store = NotifiedEventStore(defaults: defaults)
        XCTAssertEqual(store.register(npub: npub, eventIds: ["e1"]), ["e1"])

        // Many relay replays over the app's lifetime — never re-announces.
        for _ in 0..<10 {
            XCTAssertEqual(store.register(npub: npub, eventIds: ["e1"]), [])
        }

        // And after a relaunch (fresh process reading the same defaults).
        var relaunched = NotifiedEventStore(defaults: defaults)
        XCTAssertEqual(relaunched.register(npub: npub, eventIds: ["e1"]), [],
                       "a read, already-announced DM must stay suppressed after relaunch")
    }

    /// Each npub keeps its own ledger; announcing for one never affects another,
    /// even for an identical event ID.
    func testLedgerIsScopedPerNpub() {
        var store = NotifiedEventStore(defaults: makeDefaults())
        let other = "npub1bbbbbbbbbbbbbbbbbbbbbbbb"
        XCTAssertEqual(store.register(npub: npub, eventIds: ["e1"]), ["e1"])
        XCTAssertEqual(store.register(npub: other, eventIds: ["e1"]), ["e1"],
                       "the same event ID under a different npub is independent")
        XCTAssertTrue(store.contains(npub: npub, eventId: "e1"))
        XCTAssertTrue(store.contains(npub: other, eventId: "e1"))
    }

    // MARK: - Bounded growth

    /// The set is capped so a long-lived conversation can't grow UserDefaults
    /// without bound; eviction is oldest-first and keeps the most recent IDs.
    func testCapEvictsOldestKeepsRecent() {
        var store = NotifiedEventStore(defaults: makeDefaults(), maxPerNpub: 3)
        XCTAssertEqual(store.register(npub: npub, eventIds: ["e1", "e2", "e3"]), ["e1", "e2", "e3"])

        // e4 pushes out the oldest (e1).
        XCTAssertEqual(store.register(npub: npub, eventIds: ["e4"]), ["e4"])
        XCTAssertFalse(store.contains(npub: npub, eventId: "e1"), "oldest should be evicted")
        XCTAssertTrue(store.contains(npub: npub, eventId: "e2"))
        XCTAssertTrue(store.contains(npub: npub, eventId: "e4"))

        // Recent IDs are still deduped.
        XCTAssertEqual(store.register(npub: npub, eventIds: ["e3", "e4"]), [])
    }
}
