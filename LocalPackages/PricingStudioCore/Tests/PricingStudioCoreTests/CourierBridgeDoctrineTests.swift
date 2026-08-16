import XCTest
@testable import PricingStudioCore

/// Locks the Courier Bridge design guidance (pricing-studio#138) so a future
/// change cannot quietly reverse the non-negotiables. Before the doctrine type
/// existed these assertions had nowhere to bind — the guidance lived only in an
/// upstream field report. See `design/courier-bridge.md`.
final class CourierBridgeDoctrineTests: XCTestCase {

    // MARK: - Always-on delivery

    func testAlwaysOnDeliveryIsPatronOperatedBridgeNotOnDeviceSocket() {
        XCTAssertEqual(
            CourierBridgeDoctrine.alwaysOnDelivery,
            .patronOperatedCourierBridge
        )
        XCTAssertFalse(
            CourierBridgeDoctrine.onDeviceLongLivedRelayIsViable,
            "iOS tears background sockets down; a long-lived on-device relay is not viable"
        )
    }

    // MARK: - Who may run the bridge

    func testOnlyPatronMayOperateBridge() {
        XCTAssertTrue(CourierBridgeDoctrine.mayOperateBridge(.patron))
        XCTAssertFalse(
            CourierBridgeDoctrine.mayOperateBridge(.operatorService),
            "Operators must never hold device tokens"
        )
        XCTAssertFalse(
            CourierBridgeDoctrine.mayOperateBridge(.authority),
            "Authority-operated bridge must not be the default"
        )
        XCTAssertEqual(CourierBridgeDoctrine.allowedBridgeOperators, [.patron])
    }

    // MARK: - Wake push contents

    func testWakePushIsContentFreeOnly() {
        XCTAssertTrue(CourierBridgeDoctrine.mayIncludeInWakePush(.contentFree))
        XCTAssertFalse(CourierBridgeDoctrine.mayIncludeInWakePush(.claimedIdentity))
        XCTAssertFalse(CourierBridgeDoctrine.mayIncludeInWakePush(.scope))
        XCTAssertFalse(CourierBridgeDoctrine.mayIncludeInWakePush(.npub))
        XCTAssertFalse(CourierBridgeDoctrine.mayIncludeInWakePush(.challengeBody))
        XCTAssertEqual(CourierBridgeDoctrine.allowedWakePushContents, [.contentFree])
    }

    // MARK: - APNs requirement

    func testDeviceWakeRequiresAPNs() {
        XCTAssertTrue(
            CourierBridgeDoctrine.requiresAPNsForDeviceWake,
            "There is no Nostr-native substitute for waking a sleeping device"
        )
    }

    // MARK: - Watch topology

    func testPreferredWatchTopologyIsIndependentApp() {
        XCTAssertTrue(
            CourierBridgeDoctrine.prefersWatchTopology(.independentWatchApp)
        )
        XCTAssertEqual(
            CourierBridgeDoctrine.preferredWatchTopology,
            .independentWatchApp
        )
    }

    func testRejectedWatchTopologies() {
        XCTAssertTrue(
            CourierBridgeDoctrine.rejectsWatchTopology(.iphoneMirroredOnly),
            "iPhone mirroring alone is not always-on when no phone is in the path"
        )
        XCTAssertTrue(
            CourierBridgeDoctrine.rejectsWatchTopology(.ipadWatchConnectivity),
            "WatchConnectivity pairs Watch with one iPhone; iPad is not a participant"
        )
        XCTAssertFalse(
            CourierBridgeDoctrine.rejectsWatchTopology(.independentWatchApp)
        )
    }

    // MARK: - Signing gesture

    func testRejectMayCompleteLockedAcceptRequiresUnlock() {
        XCTAssertTrue(CourierBridgeDoctrine.mayComplete(.rejectWhileLocked))
        XCTAssertTrue(CourierBridgeDoctrine.mayComplete(.acceptRequiresUnlock))
        XCTAssertFalse(
            CourierBridgeDoctrine.mayComplete(.acceptWhileLocked),
            "Approval must cost a deliberate unlock gesture"
        )
    }
}
