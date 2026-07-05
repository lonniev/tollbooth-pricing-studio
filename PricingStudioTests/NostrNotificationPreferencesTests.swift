import XCTest
@testable import PricingStudio

final class NostrNotificationPreferencesTests: XCTestCase {

    private let npubA = "npub1aaaTESTfixture000000000000000000000000000000000000000000"
    private let npubB = "npub1bbbTESTfixture000000000000000000000000000000000000000000"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "notifications.mutedNpubs")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "notifications.mutedNpubs")
        super.tearDown()
    }

    func testDefaultsToEnabled() {
        XCTAssertTrue(NostrNotificationPreferences.isEnabled(npub: npubA))
        XCTAssertFalse(NostrNotificationPreferences.isMuted(npub: npubA))
    }

    func testMuteThenEnableRoundTrip() {
        NostrNotificationPreferences.setEnabled(false, npub: npubA)
        XCTAssertTrue(NostrNotificationPreferences.isMuted(npub: npubA))
        XCTAssertFalse(NostrNotificationPreferences.isEnabled(npub: npubA))

        NostrNotificationPreferences.setEnabled(true, npub: npubA)
        XCTAssertFalse(NostrNotificationPreferences.isMuted(npub: npubA))
        XCTAssertTrue(NostrNotificationPreferences.isEnabled(npub: npubA))
    }

    func testMuteIsPerNpub() {
        NostrNotificationPreferences.setEnabled(false, npub: npubA)
        XCTAssertTrue(NostrNotificationPreferences.isMuted(npub: npubA))
        XCTAssertFalse(NostrNotificationPreferences.isMuted(npub: npubB),
                       "muting one npub must not affect another")
    }

    func testMutingIsIdempotent() {
        NostrNotificationPreferences.setEnabled(false, npub: npubA)
        NostrNotificationPreferences.setEnabled(false, npub: npubA)
        // Enabling once must fully clear it — no lingering duplicate entry.
        NostrNotificationPreferences.setEnabled(true, npub: npubA)
        XCTAssertTrue(NostrNotificationPreferences.isEnabled(npub: npubA))
    }

    func testPersistsAcrossReads() {
        NostrNotificationPreferences.setEnabled(false, npub: npubB)
        // Fresh read (no in-memory cache) still reflects the muted state.
        XCTAssertTrue(NostrNotificationPreferences.isMuted(npub: npubB))
    }
}
