import PricingStudioCore
import XCTest
@testable import PricingStudio

/// Hosted companion for `CourierBridgeWake` device-token persistence
/// (pricing-studio#139). Confirms the app retains the APNs registration the
/// patron hands their own Bridge — the always-on wake path that does not
/// depend on a foreground peer device.
@MainActor
final class CourierBridgeTokenStoreTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "CourierBridgeTokenStoreTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        CourierBridgeTokenStore.clear(defaults: defaults)
        defaults = nil
        super.tearDown()
    }

    func testSaveLoadRoundTrip() {
        let reg = CourierBridgeWake.DeviceRegistration(
            deviceTokenHex: "deadbeef",
            environment: .development,
            bundleId: "com.tollbooth.dpyc.PricingStudio",
            registeredAt: Date(timeIntervalSince1970: 99)
        )
        XCTAssertNil(CourierBridgeTokenStore.load(defaults: defaults),
                     "Store starts empty — no token retained before first APNs registration")
        CourierBridgeTokenStore.save(reg, defaults: defaults)
        let loaded = CourierBridgeTokenStore.load(defaults: defaults)
        XCTAssertEqual(loaded, reg)
    }

    func testClearRemovesRegistration() {
        let reg = CourierBridgeWake.DeviceRegistration(
            deviceTokenHex: "aa",
            environment: .production,
            bundleId: "com.tollbooth.dpyc.PricingStudio",
            registeredAt: Date()
        )
        CourierBridgeTokenStore.save(reg, defaults: defaults)
        CourierBridgeTokenStore.clear(defaults: defaults)
        XCTAssertNil(CourierBridgeTokenStore.load(defaults: defaults))
    }

    func testSaveOverwritesPreviousToken() {
        let first = CourierBridgeWake.DeviceRegistration(
            deviceTokenHex: "1111",
            environment: .development,
            bundleId: "com.tollbooth.dpyc.PricingStudio",
            registeredAt: Date(timeIntervalSince1970: 1)
        )
        let second = CourierBridgeWake.DeviceRegistration(
            deviceTokenHex: "2222",
            environment: .development,
            bundleId: "com.tollbooth.dpyc.PricingStudio",
            registeredAt: Date(timeIntervalSince1970: 2)
        )
        CourierBridgeTokenStore.save(first, defaults: defaults)
        CourierBridgeTokenStore.save(second, defaults: defaults)
        XCTAssertEqual(CourierBridgeTokenStore.load(defaults: defaults)?.deviceTokenHex, "2222")
    }
}
