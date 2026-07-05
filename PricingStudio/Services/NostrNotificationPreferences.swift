import Foundation

/// Per-identity mute switch for Nostr notifications.
///
/// A person monitoring several actors (their own Patrons and Operators, plus
/// counterparties) sits on both sides of every protocol and gets banners for
/// all of them. This lets them silence the ones they only watch passively —
/// keyed by npub, device-local, defaulting to enabled.
///
/// Muting a npub suppresses only the *user-facing notification* — banners and
/// the app-icon badge contribution. Background sync (the drain, the CloudKit
/// wake, the in-app unread envelope) is untouched, so the conversation is still
/// there when the user opens the app; it just doesn't interrupt them.
enum NostrNotificationPreferences {
    private static let mutedKey = "notifications.mutedNpubs"

    /// The set of npubs the user has silenced. Stored as an array (UserDefaults
    /// has no native Set), read back as a Set for O(1) membership tests.
    private static func mutedSet() -> Set<String> {
        let stored = UserDefaults.standard.array(forKey: mutedKey) as? [String] ?? []
        return Set(stored)
    }

    private static func store(_ set: Set<String>) {
        UserDefaults.standard.set(Array(set), forKey: mutedKey)
    }

    /// True when this npub should still post notifications (the default).
    static func isEnabled(npub: String) -> Bool {
        !mutedSet().contains(npub)
    }

    static func isMuted(npub: String) -> Bool {
        mutedSet().contains(npub)
    }

    /// Enable (`true`) or silence (`false`) notifications for one npub.
    static func setEnabled(_ enabled: Bool, npub: String) {
        var set = mutedSet()
        if enabled {
            set.remove(npub)
        } else {
            set.insert(npub)
        }
        store(set)
    }
}
