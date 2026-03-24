import Foundation

/// Manages persistent Nostr relay subscriptions for all registered npubs.
///
/// Maintains one PersistentRelayConnection per relay URL, with NIP-04 + NIP-17
/// filter subscriptions for each npub that has an nsec. Delivers new events
/// to the DMPollingService via a callback.
@MainActor @Observable
final class RelaySubscriptionManager {
    static let shared = RelaySubscriptionManager()

    private(set) var connectionStates: [URL: PersistentRelayConnection.ConnectionState] = [:]
    private(set) var subscribedNpubs: Set<String> = []

    /// Callback: (npub, event) — fired on MainActor when a new event arrives.
    var onNewEvent: ((String, NostrEvent) -> Void)?

    private var connections: [URL: PersistentRelayConnection] = [:]
    private var npubSubscriptionIds: [String: [String]] = [:]  // npub → [subIds]
    private var npubKeys: [String: (pubkeyHex: String, privkeyHex: String)] = [:]
    private var npubRelayMap: [String: URL] = [:]  // npub → its current primary relay
    private var eventTasks: [URL: Task<Void, Never>] = [:]

    private init() {}

    // MARK: - Subscribe / Unsubscribe

    /// Add relay subscriptions for an npub. Safe to call multiple times (idempotent).
    /// Subscribe an npub on its primary relay only (with fallback on failure).
    func subscribe(npub: String, pubkeyHex: String, privkeyHex: String) {
        guard !subscribedNpubs.contains(npub) else { return }
        subscribedNpubs.insert(npub)
        npubKeys[npub] = (pubkeyHex, privkeyHex)

        // Get primary relay from affinity, or assign first available
        guard let primaryURL = RelaySettings.shared.primaryRelay(for: npub) else {
            TrafficLogger.shared.log(.error, label: "Sub Manager",
                                     detail: "\(npub.prefix(12))… no relays available")
            return
        }

        subscribeNpubOnRelay(npub: npub, pubkeyHex: pubkeyHex, relayURL: primaryURL)
    }

    /// Subscribe a single npub on a specific relay. Connects if needed.
    private func subscribeNpubOnRelay(npub: String, pubkeyHex: String, relayURL: URL) {
        // Ensure connection exists
        if connections[relayURL] == nil {
            connectRelay(relayURL)
        }

        guard let conn = connections[relayURL] else { return }

        let sinceTimestamp = Int(Date().timeIntervalSince1970) - (7 * 24 * 60 * 60)
        let filters = Self.buildFilters(pubkeyHex: pubkeyHex, since: sinceTimestamp)
        let subId = "\(npub.prefix(12))_\(relayURL.host ?? "relay")"
        conn.subscribe(subId: subId, filters: filters)
        npubSubscriptionIds[npub] = [subId]
        npubRelayMap[npub] = relayURL

        TrafficLogger.shared.log(.outbound, label: "Sub Manager",
                                 detail: "Subscribed \(npub.prefix(12))… on \(relayURL.host ?? "?")")
    }

    /// Rotate an npub to the next relay after its primary failed.
    func rotateRelay(for npub: String) {
        // Unsubscribe from current
        if let subIds = npubSubscriptionIds.removeValue(forKey: npub) {
            if let currentURL = npubRelayMap[npub], let conn = connections[currentURL] {
                for subId in subIds { conn.unsubscribe(subId: subId) }
            }
        }

        guard let nextURL = RelaySettings.shared.rotateAffinity(for: npub),
              let keys = npubKeys[npub] else { return }

        TrafficLogger.shared.log(.outbound, label: "Sub Rotate",
                                 detail: "\(npub.prefix(12))… → \(nextURL.host ?? "?")")
        subscribeNpubOnRelay(npub: npub, pubkeyHex: keys.pubkeyHex, relayURL: nextURL)
    }

    /// Remove relay subscriptions for an npub.
    func unsubscribe(npub: String) {
        guard subscribedNpubs.contains(npub) else { return }
        subscribedNpubs.remove(npub)
        npubKeys.removeValue(forKey: npub)

        if let subIds = npubSubscriptionIds.removeValue(forKey: npub) {
            for (_, conn) in connections {
                for subId in subIds {
                    conn.unsubscribe(subId: subId)
                }
            }
        }
    }

    // MARK: - Relay Management

    /// Connect relays that are needed by current npub affinities.
    /// Only connects relays that have at least one npub assigned.
    func connectAll() {
        let neededURLs = Set(npubRelayMap.values)
        let allURLs = neededURLs.isEmpty ? Set(RelaySettings.shared.relayURLs) : neededURLs
        TrafficLogger.shared.log(.outbound, label: "Sub Manager",
                                 detail: "Connecting to \(allURLs.count) relay(s) for subscriptions")
        for url in allURLs where connections[url] == nil {
            connectRelay(url)
        }
    }

    /// Tear down connections to relays no longer in the list, add new ones.
    func updateRelays(_ newURLs: [URL]) {
        let current = Set(connections.keys)
        let desired = Set(newURLs)

        // Remove stale
        for url in current.subtracting(desired) {
            connections[url]?.disconnect()
            connections.removeValue(forKey: url)
            connectionStates.removeValue(forKey: url)
            eventTasks[url]?.cancel()
            eventTasks.removeValue(forKey: url)
        }

        // Add new
        for url in desired.subtracting(current) {
            connectRelay(url)
        }
    }

    /// Disconnect everything.
    func disconnectAll() {
        for (_, conn) in connections { conn.disconnect() }
        connections.removeAll()
        connectionStates.removeAll()
        for (_, task) in eventTasks { task.cancel() }
        eventTasks.removeAll()
    }

    // MARK: - Private

    private func connectRelay(_ url: URL) {
        let conn = PersistentRelayConnection(url: url)
        connections[url] = conn
        connectionStates[url] = .connecting

        // Start event consumer
        let task = Task { [weak self] in
            for await event in conn.events {
                guard let self else { break }
                self.routeEvent(event)
            }
        }
        eventTasks[url] = task

        // Connect and subscribe
        Task {
            do {
                try await conn.connect()
                connectionStates[url] = .connected
                subscribeAllNpubs(on: conn, url: url)

                TrafficLogger.shared.log(.inbound, label: "Sub Manager",
                                         detail: "Connected to \(url.host ?? url.absoluteString)")
            } catch {
                connectionStates[url] = .disconnected
                TrafficLogger.shared.log(.error, label: "Sub Manager",
                                         detail: "Failed to connect \(url.host ?? url.absoluteString): \(error.localizedDescription)")
                // Rotate all npubs that were using this relay
                let affected = npubRelayMap.filter { $0.value == url }.map(\.key)
                for npub in affected {
                    rotateRelay(for: npub)
                }
            }
        }
    }

    /// Subscribe only npubs that have affinity for this relay.
    private func subscribeAllNpubs(on conn: PersistentRelayConnection, url: URL) {
        let sinceTimestamp = Int(Date().timeIntervalSince1970) - (7 * 24 * 60 * 60)
        for (npub, keys) in npubKeys {
            // Only subscribe if this npub's primary relay matches
            guard npubRelayMap[npub] == url else { continue }

            let filters = Self.buildFilters(pubkeyHex: keys.pubkeyHex, since: sinceTimestamp)
            let subId = "\(npub.prefix(12))_\(url.host ?? "relay")"
            conn.subscribe(subId: subId, filters: filters)
            npubSubscriptionIds[npub] = [subId]
        }
    }

    /// Route an incoming event to ALL matching npub callbacks.
    /// A DM where both sender and recipient are managed by the app
    /// must be delivered to both — sender sees it as outbound,
    /// recipient sees it as inbound.
    private func routeEvent(_ event: NostrEvent) {
        let pTags = event.tags.filter { $0.first == "p" }.compactMap { $0.count > 1 ? $0[1] : nil }

        TrafficLogger.shared.log(.inbound, label: "Sub Relay Event",
                                 detail: "kind=\(event.kind) from=\(event.pubkey.prefix(12))… pTags=\(pTags.map { String($0.prefix(12)) })")

        var matched = false
        for (npub, keys) in npubKeys {
            if event.pubkey == keys.pubkeyHex || pTags.contains(keys.pubkeyHex) {
                TrafficLogger.shared.log(.inbound, label: "Sub Matched",
                                         detail: "→ \(npub.prefix(12))… kind=\(event.kind)")
                onNewEvent?(npub, event)
                matched = true
            }
        }
        if !matched {
            TrafficLogger.shared.log(.inbound, label: "Sub Unmatched",
                                     detail: "kind=\(event.kind) — no npub match")
        }
    }

    // MARK: - Filter Construction

    private static func buildFilters(pubkeyHex: String, since: Int) -> [[String: Any]] {
        let nip04Inbound: [String: Any] = [
            "kinds": [4],
            "#p": [pubkeyHex],
            "since": since,
            "limit": 100,
        ]
        let nip04Outbound: [String: Any] = [
            "kinds": [4],
            "authors": [pubkeyHex],
            "since": since,
            "limit": 100,
        ]
        let giftWrap: [String: Any] = [
            "kinds": [1059],
            "#p": [pubkeyHex],
            "since": since - (48 * 60 * 60),
            "limit": 100,
        ]
        return [nip04Inbound, nip04Outbound, giftWrap]
    }
}
