import Foundation
import PricingStudioCore

/// Persists the patron's APNs device-token registration for hand-off to their
/// own Courier Bridge (pricing-studio#139 / design/courier-bridge.md).
///
/// Operators never read this store. The Bridge is patron-operated infrastructure;
/// the token leaves the device only when the patron exports it to that Bridge.
/// UserDefaults is sufficient: the token is not a secret in the Keychain sense
/// (APNs already scopes it to this app + device), and the Bridge needs the raw
/// hex to target a push.
enum CourierBridgeTokenStore {

    static let defaultsKey = "courierBridge.deviceRegistration"

    static func save(_ registration: CourierBridgeWake.DeviceRegistration, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(registration) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func load(defaults: UserDefaults = .standard) -> CourierBridgeWake.DeviceRegistration? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(CourierBridgeWake.DeviceRegistration.self, from: data)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
