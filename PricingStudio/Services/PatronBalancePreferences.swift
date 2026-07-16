import Foundation
import PricingStudioCore

/// Per-patron, device-local presentation prefs for the Credit Balances list:
/// the operator ordering the user dragged into place, and which operator cards
/// they've collapsed. Keyed by patron npub, stored in UserDefaults — a pure UI
/// concern, so it stays off the SwiftData/CloudKit model (no schema change) and
/// device-local, matching `NostrNotificationPreferences`.
enum PatronBalancePreferences {
    private static func orderKey(_ npub: String) -> String { "patronBalances.order.\(npub)" }
    private static func collapsedKey(_ npub: String) -> String { "patronBalances.collapsed.\(npub)" }

    // MARK: - Order

    /// The saved operator-npub order for this patron (empty = never reordered).
    static func order(patronNpub: String) -> [String] {
        UserDefaults.standard.array(forKey: orderKey(patronNpub)) as? [String] ?? []
    }

    static func setOrder(_ npubs: [String], patronNpub: String) {
        UserDefaults.standard.set(npubs, forKey: orderKey(patronNpub))
    }

    /// Sort `items` by `order` (a list of keys). Items whose key isn't in
    /// `order` (newly added operators) keep their incoming order and sit at the
    /// end, so the list is stable and new operators are never hidden.
    static func ordered<T>(_ items: [T], order: [String], key: (T) -> String) -> [T] {
        guard !order.isEmpty else { return items }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return items.enumerated().sorted { lhs, rhs in
            let l = rank[key(lhs.element)] ?? (order.count + lhs.offset)
            let r = rank[key(rhs.element)] ?? (order.count + rhs.offset)
            return l < r
        }.map(\.element)
    }

    // MARK: - Collapsed

    static func collapsedSet(patronNpub: String) -> Set<String> {
        Set(UserDefaults.standard.array(forKey: collapsedKey(patronNpub)) as? [String] ?? [])
    }

    static func setCollapsedSet(_ set: Set<String>, patronNpub: String) {
        UserDefaults.standard.set(Array(set), forKey: collapsedKey(patronNpub))
    }
}
