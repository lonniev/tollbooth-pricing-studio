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
    private var eventTasks: [URL: Task<Void, Never>] = [:]

    private init() {}

    // MARK: - Subscribe / Unsubscribe

    /// Add relay subscriptions for an npub. Safe to call multiple times (idempotent).
    func subscribe(npub: String, pubkeyHex: String, privkeyHex: String) {
        guard !subscribedNpubs.contains(npub) else { return }
        subscribedNpubs.insert(npub)
        npubKeys[npub] = (pubkeyHex, privkeyHex)

        let sinceTimestamp = Int(Date().timeIntervalSince1970) - (7 * 24 * 60 * 60)
        let filters = Self.buildFilters(pubkeyHex: pubkeyHex, since: sinceTimestamp)
        let subIdBase = String(npub.prefix(12))

        var subIds: [String] = []
        for (url, conn) in connections {
            let subId = "\(subIdBase)_\(url.host ?? "relay")"
            conn.subscribe(subId: subId, filters: filters)
            subIds.append(subId)
        }
        npubSubscriptionIds[npub] = subIds

        TrafficLogger.shared.log(.outbound, label: "Sub Manager",
                                 detail: "Subscribed \(npub.prefix(12))… on \(connections.count) relays")
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

    /// Connect to all configured relays and start event processing.
    func connectAll() {
        let urls = RelaySettings.shared.relayURLs
        TrafficLogger.shared.log(.outbound, label: "Sub Manager",
                                 detail: "Connecting to \(urls.count) relays for persistent subscriptions")
        for url in urls where connections[url] == nil {
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
            }
        }
    }

    private func subscribeAllNpubs(on conn: PersistentRelayConnection, url: URL) {
        let sinceTimestamp = Int(Date().timeIntervalSince1970) - (7 * 24 * 60 * 60)
        for (npub, keys) in npubKeys {
            let filters = Self.buildFilters(pubkeyHex: keys.pubkeyHex, since: sinceTimestamp)
            let subId = "\(npub.prefix(12))_\(url.host ?? "relay")"
            conn.subscribe(subId: subId, filters: filters)

            // Track the sub ID
            var ids = npubSubscriptionIds[npub] ?? []
            if !ids.contains(subId) {
                ids.append(subId)
                npubSubscriptionIds[npub] = ids
            }
        }
    }

    /// Route an incoming event to the right npub callback.
    private func routeEvent(_ event: NostrEvent) {
        let pTags = event.tags.filter { $0.first == "p" }.compactMap { $0.count > 1 ? $0[1] : nil }

        TrafficLogger.shared.log(.inbound, label: "Sub Relay Event",
                                 detail: "kind=\(event.kind) from=\(event.pubkey.prefix(12))… pTags=\(pTags.map { String($0.prefix(12)) })")

        for (npub, keys) in npubKeys {
            if event.pubkey == keys.pubkeyHex || pTags.contains(keys.pubkeyHex) {
                TrafficLogger.shared.log(.inbound, label: "Sub Matched",
                                         detail: "→ \(npub.prefix(12))… kind=\(event.kind)")
                onNewEvent?(npub, event)
                return
            }
        }
        TrafficLogger.shared.log(.inbound, label: "Sub Unmatched",
                                 detail: "kind=\(event.kind) — no npub match")
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
