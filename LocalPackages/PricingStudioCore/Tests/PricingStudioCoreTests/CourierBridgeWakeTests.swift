import XCTest
@testable import PricingStudioCore

/// Confirms the Studio-side Courier Bridge wake path (pricing-studio#139).
///
/// Before this type existed, a terminated / locked Studio could only learn about
/// a proof request via (a) a foreground WebSocket or (b) CloudKit InboxSignal
/// from another already-foregrounded peer device. Neither covers the reported
/// repro: Studio terminated, iPhone locked, no peer device awake. These tests
/// lock the content-free wake contract the app wires into remote-notification
/// handling, and the device-token registration shape the patron hands their
/// own Bridge.
final class CourierBridgeWakeTests: XCTestCase {

    // MARK: - Recognition (the defect #139 needs)

    func testRecognizesBareContentFreeWake() {
        let info: [AnyHashable: Any] = [
            CourierBridgeWake.payloadTypeKey: CourierBridgeWake.payloadTypeValue,
        ]
        XCTAssertTrue(
            CourierBridgeWake.isContentFreeWake(info),
            "Bare {courier_bridge: wake} is the lawful always-on wake"
        )
        XCTAssertNil(CourierBridgeWake.reason(in: info))
    }

    func testRecognizesWakeWithProofRequestReason() {
        let info: [AnyHashable: Any] = [
            CourierBridgeWake.payloadTypeKey: CourierBridgeWake.payloadTypeValue,
            CourierBridgeWake.reasonKey: CourierBridgeWake.proofRequestReason,
        ]
        XCTAssertTrue(CourierBridgeWake.isContentFreeWake(info))
        XCTAssertEqual(
            CourierBridgeWake.reason(in: info),
            CourierBridgeWake.proofRequestReason
        )
    }

    func testRecognizesWakeNestedUnderAps() {
        let info: [AnyHashable: Any] = [
            "aps": [
                "content-available": 1,
                CourierBridgeWake.payloadTypeKey: CourierBridgeWake.payloadTypeValue,
                CourierBridgeWake.reasonKey: CourierBridgeWake.proofRequestReason,
            ] as [String: Any],
        ]
        XCTAssertTrue(CourierBridgeWake.isContentFreeWake(info))
        XCTAssertEqual(
            CourierBridgeWake.reason(in: info),
            CourierBridgeWake.proofRequestReason
        )
    }

    func testRecognizesWakeWithGenericApsAlertBanner() {
        // A generic "connect now" banner is fine — the Bridge may raise a visible
        // padlock-style alert so the user notices, as long as it carries no
        // challenge content. Content still comes from the on-device relay fetch.
        let info: [AnyHashable: Any] = [
            "aps": [
                "alert": "🔒 Secure Courier message",
                "content-available": 1,
                "sound": "default",
            ] as [String: Any],
            CourierBridgeWake.payloadTypeKey: CourierBridgeWake.payloadTypeValue,
        ]
        XCTAssertTrue(CourierBridgeWake.isContentFreeWake(info))
    }

    func testRejectsCloudKitInboxSignalShape() {
        // InboxSignal is a separate peer-wake path; it must not be mistaken for
        // a Bridge wake (and Bridge handling must not steal CloudKit pushes).
        let info: [AnyHashable: Any] = [
            "ck": [
                "cksub": "inbox-signal-zone-v3",
            ] as [String: Any],
            "aps": ["content-available": 1] as [String: Any],
        ]
        XCTAssertFalse(CourierBridgeWake.isContentFreeWake(info))
    }

    func testRejectsMissingTypeKey() {
        XCTAssertFalse(CourierBridgeWake.isContentFreeWake([:]))
        XCTAssertFalse(CourierBridgeWake.isContentFreeWake([
            "aps": ["content-available": 1] as [String: Any],
        ]))
    }

    func testRejectsWrongTypeValue() {
        XCTAssertFalse(CourierBridgeWake.isContentFreeWake([
            CourierBridgeWake.payloadTypeKey: "challenge",
        ]))
    }

    // MARK: - Content-free doctrine (must not regress)

    func testRejectsWakeThatCarriesNpub() {
        XCTAssertFalse(
            CourierBridgeWake.isContentFreeWake([
                CourierBridgeWake.payloadTypeKey: CourierBridgeWake.payloadTypeValue,
                "npub": "npub1patron",
            ]),
            "Doctrine: wake pushes carry no npub"
        )
    }

    func testRejectsWakeThatCarriesClaimedIdentity() {
        XCTAssertFalse(CourierBridgeWake.isContentFreeWake([
            CourierBridgeWake.payloadTypeKey: CourierBridgeWake.payloadTypeValue,
            "claimed_identity": "alice",
        ]))
        XCTAssertFalse(CourierBridgeWake.isContentFreeWake([
            CourierBridgeWake.payloadTypeKey: CourierBridgeWake.payloadTypeValue,
            "claimedIdentity": "alice",
        ]))
    }

    func testRejectsWakeThatCarriesScopeOrChallenge() {
        XCTAssertFalse(CourierBridgeWake.isContentFreeWake([
            CourierBridgeWake.payloadTypeKey: CourierBridgeWake.payloadTypeValue,
            "scope": "request_npub_proof",
        ]))
        XCTAssertFalse(CourierBridgeWake.isContentFreeWake([
            CourierBridgeWake.payloadTypeKey: CourierBridgeWake.payloadTypeValue,
            "challenge_body": "please approve",
        ]))
        XCTAssertFalse(CourierBridgeWake.isContentFreeWake([
            CourierBridgeWake.payloadTypeKey: CourierBridgeWake.payloadTypeValue,
            "dpop_token": "faint-dusk-55",
        ]))
        XCTAssertFalse(CourierBridgeWake.isContentFreeWake([
            CourierBridgeWake.payloadTypeKey: CourierBridgeWake.payloadTypeValue,
            "payload": ["confirm": "x"] as [String: Any],
        ]))
    }

    func testRejectsUnknownCustomRootKeys() {
        // Anything beyond the bare wake markers is content. Keep the surface
        // closed so a future Bridge cannot quietly smuggle fields.
        XCTAssertFalse(CourierBridgeWake.isContentFreeWake([
            CourierBridgeWake.payloadTypeKey: CourierBridgeWake.payloadTypeValue,
            "extra": "nope",
        ]))
    }

    func testReasonIsNilWhenPayloadIsUnlawful() {
        let info: [AnyHashable: Any] = [
            CourierBridgeWake.payloadTypeKey: CourierBridgeWake.payloadTypeValue,
            "npub": "npub1x",
            CourierBridgeWake.reasonKey: CourierBridgeWake.proofRequestReason,
        ]
        XCTAssertNil(
            CourierBridgeWake.reason(in: info),
            "Reason must not be readable off an unlawful (content-bearing) payload"
        )
    }

    // MARK: - Device token registration shape

    func testHexEncodesDeviceToken() {
        let token = Data([0xde, 0xad, 0xbe, 0xef, 0x00, 0x0f])
        XCTAssertEqual(
            CourierBridgeWake.hexEncodeDeviceToken(token),
            "deadbeef000f"
        )
    }

    func testMakeRegistrationCapturesTokenEnvironmentAndBundle() {
        let token = Data([0x01, 0x02, 0xaa])
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reg = CourierBridgeWake.makeRegistration(
            deviceToken: token,
            environment: .development,
            bundleId: "com.tollbooth.dpyc.PricingStudio",
            now: now
        )
        XCTAssertEqual(reg.deviceTokenHex, "0102aa")
        XCTAssertEqual(reg.environment, .development)
        XCTAssertEqual(reg.bundleId, "com.tollbooth.dpyc.PricingStudio")
        XCTAssertEqual(reg.registeredAt, now)
    }

    func testRegistrationIsCodableForPatronBridgeHandOff() throws {
        let reg = CourierBridgeWake.DeviceRegistration(
            deviceTokenHex: "abc123",
            environment: .production,
            bundleId: "com.tollbooth.dpyc.PricingStudio",
            registeredAt: Date(timeIntervalSince1970: 42)
        )
        let data = try JSONEncoder().encode(reg)
        let decoded = try JSONDecoder().decode(CourierBridgeWake.DeviceRegistration.self, from: data)
        XCTAssertEqual(decoded, reg)
    }

    /// Doctrine cross-check: the registration path is for the *patron's* Bridge.
    /// Operators must never hold tokens — this is the machine-readable reminder
    /// that DeviceRegistration is not an Operator-facing API.
    func testDeviceRegistrationIsPatronBridgeOnly() {
        XCTAssertTrue(CourierBridgeDoctrine.mayOperateBridge(.patron))
        XCTAssertFalse(CourierBridgeDoctrine.mayOperateBridge(.operatorService))
        XCTAssertTrue(CourierBridgeDoctrine.requiresAPNsForDeviceWake)
        XCTAssertTrue(CourierBridgeDoctrine.mayIncludeInWakePush(.contentFree))
        XCTAssertFalse(CourierBridgeDoctrine.mayIncludeInWakePush(.npub))
    }
}
