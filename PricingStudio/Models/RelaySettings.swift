import Foundation

@MainActor @Observable
class RelaySettings {
    static let shared = RelaySettings()

    nonisolated static let storageKey = "nostr.relays"
    nonisolated static let affinityStorageKey = "nostr.relayAffinities"
    nonisolated static let defaultRelayStrings = [
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://relay.0xchat.com",
        "wss://relay.nostr.band",
    ]

    var onRelaysChanged: (([URL]) -> Void)?

    var relays: [String] {
        didSet {
            save()
            onRelaysChanged?(relayURLs)
        }
    }

    var relayURLs: [URL] {
        relays.compactMap { URL(string: $0) }
    }

    // MARK: - Relay Affinity

    /// Per-npub relay affinity — tracks which relay works best for each npub's subscriptions.
    /// Key: npub, Value: RelayAffinity
    private(set) var affinities: [String: RelayAffinity] = [:]

    struct RelayAffinity: Codable {
        let npub: String
        var primaryRelay: String  // URL string
        var lastSuccessAt: Date

        var primaryURL: URL? { URL(string: primaryRelay) }
    }

    /// Get the preferred relay for an npub, or nil if no affinity established.
    func affinity(for npub: String) -> URL? {
        affinities[npub]?.primaryURL
    }

    /// Record that a relay successfully delivered events for an npub.
    func updateAffinity(npub: String, relay: URL) {
        affinities[npub] = RelayAffinity(
            npub: npub,
            primaryRelay: relay.absoluteString,
            lastSuccessAt: Date()
        )
        saveAffinities()
    }

    /// Rotate to the next relay in the pool for an npub whose primary failed.
    /// Returns the new relay URL, or nil if no relays available.
    func rotateAffinity(for npub: String) -> URL? {
        let pool = relayURLs
        guard !pool.isEmpty else { return nil }

        let currentPrimary = affinities[npub]?.primaryURL
        let currentIndex = currentPrimary.flatMap { url in pool.firstIndex(of: url) } ?? -1
        let nextIndex = (currentIndex + 1) % pool.count
        let next = pool[nextIndex]

        affinities[npub] = RelayAffinity(
            npub: npub,
            primaryRelay: next.absoluteString,
            lastSuccessAt: Date()
        )
        saveAffinities()
        return next
    }

    /// Get the primary relay for an npub, or assign the first available relay.
    func primaryRelay(for npub: String) -> URL? {
        if let existing = affinity(for: npub) { return existing }
        guard let first = relayURLs.first else { return nil }
        updateAffinity(npub: npub, relay: first)
        return first
    }

    // MARK: - Init

    private init() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.storageKey) {
            relays = saved
        } else {
            relays = Self.defaultRelayStrings
        }
        loadAffinities()
    }

    func resetToDefaults() {
        relays = Self.defaultRelayStrings
        affinities.removeAll()
        saveAffinities()
    }

    // MARK: - Persistence

    private func save() {
        UserDefaults.standard.set(relays, forKey: Self.storageKey)
    }

    private func saveAffinities() {
        if let data = try? JSONEncoder().encode(Array(affinities.values)) {
            UserDefaults.standard.set(data, forKey: Self.affinityStorageKey)
        }
    }

    private func loadAffinities() {
        guard let data = UserDefaults.standard.data(forKey: Self.affinityStorageKey),
              let saved = try? JSONDecoder().decode([RelayAffinity].self, from: data) else { return }
        affinities = Dictionary(uniqueKeysWithValues: saved.map { ($0.npub, $0) })
    }
}
