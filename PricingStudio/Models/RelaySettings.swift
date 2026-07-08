import Foundation

/// The app's cached view of the DPYC supported-relay set.
///
/// There is NO hardcoded relay list. The set comes from the community registry
/// (`dpyc-community/relays.json`, via ``RelayRegistryService``), is cached in
/// UserDefaults, and is refreshed only when the cache is older than 3 days.
/// On a cold first launch the cache is empty until ``refresh()`` completes;
/// `onRelaysChanged` fires once the fetched set arrives so subscribers can
/// (re)connect.
@MainActor @Observable
class RelaySettings {
    static let shared = RelaySettings()

    nonisolated static let storageKey = "nostr.relays"
    nonisolated static let fetchedAtKey = "nostr.relays.fetchedAt"
    nonisolated static let cacheTTL: TimeInterval = 3 * 24 * 60 * 60  // 3 days

    var onRelaysChanged: (([URL]) -> Void)?

    /// The cached relay URLs (primary first). Empty until the first fetch lands.
    private(set) var relays: [String] {
        didSet {
            save()
            onRelaysChanged?(relayURLs)
        }
    }

    /// When the cache was last successfully refreshed (nil = never).
    private(set) var fetchedAt: Date?

    var relayURLs: [URL] {
        relays.compactMap { URL(string: $0) }
    }

    var isStale: Bool {
        guard let fetchedAt else { return true }
        return Date().timeIntervalSince(fetchedAt) >= Self.cacheTTL
    }

    // MARK: - Init

    private init() {
        relays = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []
        let ts = UserDefaults.standard.double(forKey: Self.fetchedAtKey)
        fetchedAt = ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }

    // MARK: - Refresh

    /// Refresh the relay set from the community registry when the cache is
    /// stale (or empty), or when ``force`` is true. On fetch failure the
    /// existing cached set is kept (stale-if-error).
    func refresh(force: Bool = false) async {
        if !force && !isStale && !relays.isEmpty { return }
        do {
            let fetched = try await RelayRegistryService.fetchRelays()
            guard !fetched.isEmpty else { return }
            if fetched != relays {
                relays = fetched  // didSet → save + onRelaysChanged
            }
            fetchedAt = Date()
            UserDefaults.standard.set(fetchedAt!.timeIntervalSince1970, forKey: Self.fetchedAtKey)
        } catch {
            // Stale-if-error: keep the last-known-good cached set.
        }
    }

    // MARK: - Persistence

    private func save() {
        UserDefaults.standard.set(relays, forKey: Self.storageKey)
    }
}
