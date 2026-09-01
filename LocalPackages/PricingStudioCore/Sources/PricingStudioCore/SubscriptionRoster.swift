import Foundation

/// Pure roster↔subscription set diff used by `DMPollingService.reconcileSubscriptions`.
///
/// Extracted into PricingStudioCore so the mid-session adoption gap (issue #148)
/// is unit-testable host-free via `swift test`, without standing up WebSockets,
/// the app host, or the `RelaySubscriptionManager` singleton.
public enum SubscriptionRoster {
    /// npubs that should gain a live subscription, and npubs whose subscription
    /// should be torn down because they left the roster.
    public struct Diff: Equatable, Sendable {
        public var toSubscribe: Set<String>
        public var toUnsubscribe: Set<String>

        public init(toSubscribe: Set<String>, toUnsubscribe: Set<String>) {
            self.toSubscribe = toSubscribe
            self.toUnsubscribe = toUnsubscribe
        }
    }

    /// `roster` is the set of keyed entity npubs currently known to the app;
    /// `subscribed` is `RelaySubscriptionManager.subscribedNpubs`.
    public static func diff(roster: Set<String>, subscribed: Set<String>) -> Diff {
        Diff(
            toSubscribe: roster.subtracting(subscribed),
            toUnsubscribe: subscribed.subtracting(roster)
        )
    }
}
