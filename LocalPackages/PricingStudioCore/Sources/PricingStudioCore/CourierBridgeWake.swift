import Foundation

/// Studio-side Courier Bridge wake handling (pricing-studio#139).
///
/// The patron-operated Bridge sends a **content-free** APNs wake when a proof
/// request lands on a relay while Pricing Studio is backgrounded or terminated.
/// This type is pure recognition + registration shape — no networking, no APNs
/// SDK calls. The app wires it into `didReceiveRemoteNotification` and
/// `didRegisterForRemoteNotifications`.
///
/// Doctrine constraints (see `CourierBridgeDoctrine` / `design/courier-bridge.md`):
/// - Wake pushes carry nothing but "connect now."
/// - Operators never hold device tokens; only the patron's bridge does.
/// - After wake, the device itself fetches the real payload from relays.
public enum CourierBridgeWake: Sendable {

    /// Stable custom data key the Bridge puts in the APNs payload root (or under
    /// `aps`) so the app can distinguish a Bridge wake from CloudKit InboxSignal
    /// pushes and ordinary silent system traffic.
    public static let payloadTypeKey = "courier_bridge"

    /// Only lawful value for `payloadTypeKey`. Anything else is not a Bridge wake.
    public static let payloadTypeValue = "wake"

    /// Optional Bridge-supplied reason tag. Never carries identity, scope, npub,
    /// or challenge body — just a short machine code ("proof_request").
    public static let reasonKey = "reason"

    /// Default reason the Bridge uses for Secure Courier npub-proof wakes.
    public static let proofRequestReason = "proof_request"

    // MARK: - Recognition

    /// Whether a remote-notification `userInfo` is a lawful content-free Courier
    /// Bridge wake.
    ///
    /// Lawful shape (any of):
    /// ```
    /// { "courier_bridge": "wake" }
    /// { "courier_bridge": "wake", "reason": "proof_request" }
    /// { "aps": { ... }, "courier_bridge": "wake" }
    /// ```
    ///
    /// Rejects:
    /// - Missing / wrong type key (CloudKit, unknown pushers).
    /// - Any content-bearing keys forbidden by doctrine (claimed identity, scope,
    ///   npub, challenge body, alert title/body that smuggles payload).
    /// - Nested content under a custom `data` / `payload` / `challenge` bag.
    public static func isContentFreeWake(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard typeValue(in: userInfo) == payloadTypeValue else { return false }
        return !carriesForbiddenContent(userInfo)
    }

    /// Extract the optional Bridge reason when the payload is a lawful wake.
    public static func reason(in userInfo: [AnyHashable: Any]) -> String? {
        guard isContentFreeWake(userInfo) else { return nil }
        if let r = userInfo[reasonKey] as? String, !r.isEmpty { return r }
        if let aps = userInfo["aps"] as? [AnyHashable: Any],
           let r = aps[reasonKey] as? String, !r.isEmpty {
            return r
        }
        return nil
    }

    // MARK: - Device token registration (patron → Bridge)

    /// What the patron hands their own Bridge so it can push wakes. Operators
    /// never see this. Pure value — persistence and transport live in the app.
    public struct DeviceRegistration: Equatable, Sendable, Codable {
        /// Hex-encoded APNs device token (no angle brackets / spaces).
        public let deviceTokenHex: String
        /// APNs environment the token was minted under.
        public let environment: APNsEnvironment
        /// Bundle id the token belongs to (Bridge must target the matching topic).
        public let bundleId: String
        /// When the app last observed this token from the system.
        public let registeredAt: Date

        public init(
            deviceTokenHex: String,
            environment: APNsEnvironment,
            bundleId: String,
            registeredAt: Date
        ) {
            self.deviceTokenHex = deviceTokenHex
            self.environment = environment
            self.bundleId = bundleId
            self.registeredAt = registeredAt
        }
    }

    public enum APNsEnvironment: String, Sendable, Codable, CaseIterable {
        case development
        case production
    }

    /// Hex-encode a raw APNs device token the way Bridge registration expects.
    public static func hexEncodeDeviceToken(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    /// Build a registration record from a fresh system token.
    public static func makeRegistration(
        deviceToken: Data,
        environment: APNsEnvironment,
        bundleId: String,
        now: Date = Date()
    ) -> DeviceRegistration {
        DeviceRegistration(
            deviceTokenHex: hexEncodeDeviceToken(deviceToken),
            environment: environment,
            bundleId: bundleId,
            registeredAt: now
        )
    }

    // MARK: - Internals

    private static func typeValue(in userInfo: [AnyHashable: Any]) -> String? {
        if let v = userInfo[payloadTypeKey] as? String { return v }
        if let aps = userInfo["aps"] as? [AnyHashable: Any],
           let v = aps[payloadTypeKey] as? String {
            return v
        }
        return nil
    }

    /// Keys that must never appear on a wake push (doctrine: content-free only).
    /// `aps.alert` is allowed as a generic "connect now" banner — but not when it
    /// embeds structured challenge fields. We reject explicit content bags and
    /// known forbidden field names at the payload root.
    private static let forbiddenRootKeys: Set<String> = [
        "claimed_identity", "claimedIdentity",
        "scope",
        "npub",
        "challenge", "challenge_body", "challengeBody",
        "dpop_token", "dpopToken",
        "payload", "data", "content",
        "signer", "operator_npub", "operatorNpub",
    ]

    private static func carriesForbiddenContent(_ userInfo: [AnyHashable: Any]) -> Bool {
        for (key, value) in userInfo {
            let k = String(describing: key)
            if k == "aps" {
                if let aps = value as? [AnyHashable: Any], apsCarriesForbiddenContent(aps) {
                    return true
                }
                continue
            }
            if k == payloadTypeKey || k == reasonKey { continue }
            if forbiddenRootKeys.contains(k) { return true }
            // Any other custom root key is treated as content — wake must be bare.
            return true
        }
        return false
    }

    private static func apsCarriesForbiddenContent(_ aps: [AnyHashable: Any]) -> Bool {
        for (key, _) in aps {
            let k = String(describing: key)
            // Standard APS keys are fine (alert as generic banner, content-available, sound…).
            let allowedAps: Set<String> = [
                "alert", "badge", "sound", "content-available", "mutable-content",
                "category", "thread-id", "interruption-level", "relevance-score",
                "target-content-id",
                payloadTypeKey, reasonKey,
            ]
            if allowedAps.contains(k) { continue }
            if forbiddenRootKeys.contains(k) { return true }
            // Unknown aps custom key → treat as content.
            return true
        }
        return false
    }
}
