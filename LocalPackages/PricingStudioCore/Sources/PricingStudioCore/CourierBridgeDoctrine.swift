import Foundation

/// Frozen design doctrine for waking sleeping devices to handle Secure Courier
/// npub-proof consent (pricing-studio#138 / excalibur-mcp#256).
///
/// The companion prose lives in `design/courier-bridge.md`. This type exists so
/// the non-negotiables are machine-checkable: a future implementer cannot quietly
/// reverse "Operators never hold device tokens" or "wake pushes carry no content"
/// without a failing unit test. Pure data — no networking, no APNs, no Keychain.
public enum CourierBridgeDoctrine: Sendable {

    // MARK: - Architecture choice

    /// How always-on delivery is supposed to work. An on-device long-lived
    /// WebSocket is deliberately absent: iOS tears sockets down after ~30s of
    /// background execution, and no background mode covers "hold a relay open."
    public enum AlwaysOnDelivery: String, Sendable, Codable, CaseIterable {
        /// Patron-operated always-on process that watches relays and sends APNs.
        case patronOperatedCourierBridge = "patron_operated_courier_bridge"
    }

    /// Who is allowed to hold the `npub → device token` map and send wakes.
    public enum BridgeOperator: String, Sendable, Codable, CaseIterable {
        case patron = "patron"
        case operatorService = "operator"
        case authority = "authority"
    }

    /// What a wake push may contain. Only the content-free variant is lawful:
    /// Apple sees timing; the device fetches the real payload from relays itself.
    public enum WakePushContents: String, Sendable, Codable, CaseIterable {
        case contentFree = "content_free"
        case claimedIdentity = "claimed_identity"
        case scope = "scope"
        case npub = "npub"
        case challengeBody = "challenge_body"
    }

    /// Where Accept / Reject signing may complete relative to device lock.
    public enum SigningGesture: String, Sendable, Codable, CaseIterable {
        /// Safe direction — frictionless even while locked.
        case rejectWhileLocked = "reject_while_locked"
        /// Approval costs a deliberate unlock gesture.
        case acceptRequiresUnlock = "accept_requires_unlock"
        /// Forbidden: approving from a locked device without unlock.
        case acceptWhileLocked = "accept_while_locked"
    }

    /// Preferred Watch topology once Apple docs are re-confirmed at build time.
    public enum WatchTopology: String, Sendable, Codable, CaseIterable {
        /// Independent watchOS app with its own APNs token (preferred).
        case independentWatchApp = "independent_watch_app"
        /// iPhone-mirrored local notification only (insufficient as the sole path).
        case iphoneMirroredOnly = "iphone_mirrored_only"
        /// iPad → WatchConnectivity (impossible — iPad is not in the WC session).
        case ipadWatchConnectivity = "ipad_watch_connectivity"
    }

    // MARK: - Frozen answers

    /// Always-on delivery is the patron-operated Courier Bridge — never an
    /// on-device long-lived relay socket.
    public static let alwaysOnDelivery: AlwaysOnDelivery = .patronOperatedCourierBridge

    /// Only the patron may operate the bridge. Operators and Authorities must
    /// never hold device tokens (behavioral log + "whoever can push can prompt").
    public static let allowedBridgeOperators: Set<BridgeOperator> = [.patron]

    /// Wake pushes carry nothing but "connect now."
    public static let allowedWakePushContents: Set<WakePushContents> = [.contentFree]

    /// Reject may complete locked; Accept requires unlock.
    public static let allowedSigningGestures: Set<SigningGesture> = [
        .rejectWhileLocked,
        .acceptRequiresUnlock,
    ]

    /// Preferred Watch path: independent app with its own token. Confirm against
    /// current Apple documentation before committing the Watch target.
    public static let preferredWatchTopology: WatchTopology = .independentWatchApp

    /// Topologies that must not be treated as the always-on solution.
    public static let rejectedWatchTopologies: Set<WatchTopology> = [
        .iphoneMirroredOnly,
        .ipadWatchConnectivity,
    ]

    /// Waking a sleeping device requires APNs. There is no Nostr-native substitute.
    public static let requiresAPNsForDeviceWake: Bool = true

    /// On-device long-lived relay sockets are not a viable always-on path.
    public static let onDeviceLongLivedRelayIsViable: Bool = false

    // MARK: - Predicates

    /// Whether `who` may run the bridge and hold device tokens.
    public static func mayOperateBridge(_ who: BridgeOperator) -> Bool {
        allowedBridgeOperators.contains(who)
    }

    /// Whether a wake push may include `contents`.
    public static func mayIncludeInWakePush(_ contents: WakePushContents) -> Bool {
        allowedWakePushContents.contains(contents)
    }

    /// Whether `gesture` is an allowed Accept/Reject completion policy.
    public static func mayComplete(_ gesture: SigningGesture) -> Bool {
        allowedSigningGestures.contains(gesture)
    }

    /// Whether `topology` is rejected as the always-on Watch path.
    public static func rejectsWatchTopology(_ topology: WatchTopology) -> Bool {
        rejectedWatchTopologies.contains(topology)
    }

    /// Whether `topology` is the preferred independent-Watch direction.
    public static func prefersWatchTopology(_ topology: WatchTopology) -> Bool {
        topology == preferredWatchTopology
    }
}
