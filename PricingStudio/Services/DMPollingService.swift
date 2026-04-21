import Foundation
import SwiftData
import UserNotifications

/// Polls Nostr relays for new DMs across all entities with stored nsec keys.
@MainActor @Observable
final class DMPollingService {
    static let shared = DMPollingService()

    private(set) var unreadCounts: [String: Int] = [:]
    private(set) var lastPollAt: Date?
    private(set) var pollCycle: Int = 0
    private(set) var subscriptionsActive: Bool = false
    private var isFirstPoll = true
    private var subscriptionsStartedAt: Date?
    private var lastSeenTimestamps: [String: Int] = [:]
    private var pollingTask: Task<Void, Never>?

    /// User-configurable poll interval in seconds. Persisted in UserDefaults.
    var pollIntervalSeconds: Double {
        get {
            let v = UserDefaults.standard.double(forKey: "dm.pollIntervalSeconds")
            return v > 0 ? min(max(v, 2), 120) : 5  // default 5s, range 2-120s
        }
        set { UserDefaults.standard.set(newValue, forKey: "dm.pollIntervalSeconds") }
    }

    private var pollInterval: TimeInterval { pollIntervalSeconds }

    private init() { loadLastSeen() }

    // MARK: - Public API

    func hasUnread(for npub: String) -> Bool { (unreadCounts[npub] ?? 0) > 0 }

    /// Callback for live DM delivery — ChatViewModel registers this to
    /// inject messages directly into the active conversation without relay fetch.
    var onLiveDM: ((String, DecryptedDM) -> Void)?

    /// Resolve a pubkey hex or npub to a display name. Wired by ContentView
    /// which has SwiftData access. Returns alias > displayName > npub fingerprint.
    var resolveDisplayName: ((String) -> String)?

    /// Signal that something changed — triggers onChange watchers.
    func notifyUpdate() { lastPollAt = Date() }
    func unreadCount(for npub: String) -> Int { unreadCounts[npub] ?? 0 }
    var isPolling: Bool { pollingTask != nil }

    func markRead(npub: String) {
        var updated = unreadCounts
        updated[npub] = 0
        unreadCounts = updated
        lastSeenTimestamps[npub] = Int(Date().timeIntervalSince1970)
        saveLastSeen()
    }

    func startPolling(modelContext: ModelContext) {
        if pollingTask != nil { return }
        requestNotificationPermission()
        startSubscriptions(modelContext: modelContext)
        TrafficLogger.shared.log(.outbound, label: "DM Poll Start", detail: "Background polling started (\(Int(pollInterval))s interval, subs=\(subscriptionsActive))")

        pollingTask = Task {
            while !Task.isCancelled {
                self.pollCycle += 1
                let cycle = self.pollCycle

                let entities = self.gatherEntities(modelContext: modelContext)
                let timestamps = self.lastSeenTimestamps
                let withKeys = entities.filter { $0.hasKeys }.count

                TrafficLogger.shared.log(.outbound, label: "DM Poll Cycle \(cycle)", detail: "\(entities.count) entities (\(withKeys) with nsec)")

                if !entities.isEmpty {
                    // When subscriptions are active, skip relay fetches to avoid
                    // duplicate connections that cause timeouts. Subscriptions
                    // deliver new events; polling just maintains the heartbeat.
                    if self.subscriptionsActive {
                        if self.isFirstPoll { self.isFirstPoll = false }
                    } else {
                        // Use Task.detached to GUARANTEE no MainActor inheritance
                        let results = await Task.detached {
                            await dmPollEntities(
                                entities: entities,
                                timestamps: timestamps,
                                cycle: cycle
                            )
                        }.value

                        if self.isFirstPoll {
                            self.applyTimestampsOnly(results)
                            self.isFirstPoll = false
                        } else {
                            self.applyResults(results)
                        }
                    }
                }

                self.lastPollAt = Date()
                TrafficLogger.shared.log(.inbound, label: "DM Poll Done \(cycle)", detail: "Cycle complete")

                do {
                    try await Task.sleep(for: .seconds(self.pollInterval))
                } catch { break }
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        RelaySubscriptionManager.shared.disconnectAll()
        subscriptionsActive = false
    }

    // MARK: - Subscriptions

    private func startSubscriptions(modelContext: ModelContext) {
        let subManager = RelaySubscriptionManager.shared
        let dmService = NostrDMService()

        // Wire event callback: decrypt incoming events and update unread counts.
        // Only events created AFTER subscriptions started trigger badges/notifications.
        // Historical backfill from the `since` window is ignored.
        subManager.onNewEvent = { [weak self] npub, event in
            guard let self else { return }

            // Skip decryption entirely for old events — they clog the queue
            // and delay processing of genuinely new DMs
            // No timestamp filtering — let dedup handle duplicates.
            // Previous filter was dropping valid NIP-04 DMs from MCPs.

            guard let privKeyHex = KeychainService.loadNsec(forNpub: npub)
                    .flatMap({ try? NostrKeyService.privateKeyHexFromNsec($0) }),
                  let pubKeyHex = try? NostrKeyService.publicKeyHexFromNpub(npub) else {
                TrafficLogger.shared.log(.error, label: "Sub Decrypt",
                                         detail: "\(npub.prefix(12))… no nsec — cannot decrypt kind=\(event.kind)")
                return
            }

            Task.detached(priority: .userInitiated) {
                let decrypted = await dmService.decryptEvent(
                    event, privateKeyHex: privKeyHex, publicKeyHex: pubKeyHex
                )
                if decrypted == nil {
                    await MainActor.run {
                        TrafficLogger.shared.log(.error, label: "Sub Decrypt",
                                                 detail: "\(npub.prefix(12))… decryption failed kind=\(event.kind) from=\(event.pubkey.prefix(12))…")
                    }
                }
                if let dm = decrypted {
                    await MainActor.run {
                        // Always deliver to ChatViewModel for live conversation update
                        self.onLiveDM?(npub, dm)

                        // Only badge + notify for genuinely new inbound messages
                        // (not historical backfill, not our own sent messages)
                        let isNew = self.subscriptionsStartedAt == nil
                            || dm.createdAt > (self.subscriptionsStartedAt! - 60)  // 60s grace for clock skew
                        if !dm.isFromMe && isNew {
                            var updated = self.unreadCounts
                            updated[npub] = (updated[npub] ?? 0) + 1
                            self.unreadCounts = updated
                            // Redact courier payloads — don't leak secrets in notifications or logs
                            let isCourier = dm.content.contains("@@@")
                            let safePreview = isCourier ? "🔒 Secure Courier message" : String(dm.content.prefix(80))
                            self.postLocalNotification(npub: npub, preview: safePreview, dm: dm)
                        }
                        self.lastPollAt = Date()
                        let isCourierLog = dm.content.contains("@@@")
                        TrafficLogger.shared.log(.inbound, label: "Sub Event",
                                                 detail: "\(npub.prefix(12))… kind=\(event.kind) isNew=\(isNew) isFromMe=\(dm.isFromMe) from=\(dm.senderPubkeyHex.prefix(8))… \(isCourierLog ? "content=[REDACTED courier]" : "content=\(String(dm.content.prefix(40)))")")
                    }
                }
            }
        }

        // Wire relay settings changes
        RelaySettings.shared.onRelaysChanged = { [weak subManager] newURLs in
            subManager?.updateRelays(newURLs)
        }

        // Subscribe all entities with nsecs
        let entities = gatherEntities(modelContext: modelContext)
        let keyed = entities.filter { $0.hasKeys }
        if !keyed.isEmpty {
            subManager.connectAll()
            for entity in keyed {
                if let pubKeyHex = entity.pubKeyHex, let privKeyHex = entity.privKeyHex {
                    subManager.subscribe(npub: entity.npub, pubkeyHex: pubKeyHex, privkeyHex: privKeyHex)
                }
            }
            subscriptionsActive = true
            subscriptionsStartedAt = Date()
            TrafficLogger.shared.log(.outbound, label: "Subscriptions", detail: "Started for \(keyed.count) npubs")
        }
    }

    // MARK: - Gather entities (MainActor)

    private func gatherEntities(modelContext: ModelContext) -> [DMPollEntity] {
        let operators = (try? modelContext.fetch(FetchDescriptor<Operator>())) ?? []
        let patrons = (try? modelContext.fetch(FetchDescriptor<Patron>())) ?? []
        let authorities = (try? modelContext.fetch(FetchDescriptor<Authority>())) ?? []
        let allNpubs = operators.map(\.npub) + patrons.map(\.npub) + authorities.map(\.npub)

        return allNpubs.map { npub in
            let nsec = KeychainService.loadNsec(forNpub: npub)
            let privKeyHex = nsec.flatMap { try? NostrKeyService.privateKeyHexFromNsec($0) }
            let pubKeyHex = try? NostrKeyService.publicKeyHexFromNpub(npub)
            return DMPollEntity(npub: npub, privKeyHex: privKeyHex, pubKeyHex: pubKeyHex)
        }
    }

    // MARK: - Apply results (MainActor)

    private func applyResults(_ results: [DMPollResult]) {
        var updated = unreadCounts
        for r in results {
            if r.newCount > 0 {
                updated[r.npub] = (updated[r.npub] ?? 0) + r.newCount
                postLocalNotification(npub: r.npub, preview: "\(r.newCount) new message\(r.newCount == 1 ? "" : "s")")
            }
            let lastSeen = lastSeenTimestamps[r.npub] ?? 0
            if r.latestTimestamp > lastSeen {
                lastSeenTimestamps[r.npub] = r.latestTimestamp
                saveLastSeen()
            }
        }
        unreadCounts = updated
    }

    /// First poll only: update timestamps without incrementing unread counts.
    /// This prevents stale messages from showing as "new" on app restart.
    private func applyTimestampsOnly(_ results: [DMPollResult]) {
        for r in results {
            let lastSeen = lastSeenTimestamps[r.npub] ?? 0
            if r.latestTimestamp > lastSeen {
                lastSeenTimestamps[r.npub] = r.latestTimestamp
            }
        }
        saveLastSeen()
    }

    // MARK: - OS Notifications

    enum NotificationMode: String, CaseIterable {
        case off = "off"
        case deduplicated = "deduplicated"
        case allRelays = "all_relays"

        var label: String {
            switch self {
            case .off: "Off"
            case .deduplicated: "Deduplicated"
            case .allRelays: "All Relays"
            }
        }

        var description: String {
            switch self {
            case .off: "No DM notifications"
            case .deduplicated: "One notification per message (recommended)"
            case .allRelays: "Notify for every relay delivery"
            }
        }
    }

    private static let notificationModeKey = "dm.notificationMode"

    var notificationMode: NotificationMode {
        get {
            let raw = UserDefaults.standard.string(forKey: Self.notificationModeKey) ?? "deduplicated"
            return NotificationMode(rawValue: raw) ?? .deduplicated
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.notificationModeKey)
        }
    }

    /// Event IDs that have already triggered a notification (dedup window).
    private var notifiedEventIds: Set<String> = []
    private var notifiedEventTimestamps: [String: Date] = [:]
    private static let dedupWindow: TimeInterval = 300  // 5 minutes

    private func pruneNotifiedEvents() {
        let cutoff = Date().addingTimeInterval(-Self.dedupWindow)
        let expired = notifiedEventTimestamps.filter { $0.value < cutoff }.map(\.key)
        for id in expired {
            notifiedEventIds.remove(id)
            notifiedEventTimestamps.removeValue(forKey: id)
        }
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func postLocalNotification(npub: String, preview: String? = nil, dm: DecryptedDM? = nil) {
        switch notificationMode {
        case .off:
            return
        case .deduplicated:
            if let dm {
                pruneNotifiedEvents()
                guard !notifiedEventIds.contains(dm.rawEventId) else { return }
                notifiedEventIds.insert(dm.rawEventId)
                notifiedEventTimestamps[dm.rawEventId] = Date()
            }
        case .allRelays:
            break  // no filtering
        }
        let resolve = resolveDisplayName ?? { key in String(key.prefix(16)) + "…" }

        let senderName: String
        let receiverName: String
        if let dm {
            senderName = resolve(dm.senderPubkeyHex)
            receiverName = resolve(dm.recipientPubkeyHex)
        } else {
            senderName = "unknown"
            receiverName = resolve(npub)
        }

        let content = UNMutableNotificationContent()
        content.title = "New Nostr DM"
        content.body = "From \(senderName) to \(receiverName)"
        if let preview, !preview.isEmpty {
            content.body += "\n\(preview)"
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "dm-\(npub)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Persistence

    private static let storageKey = "dm.lastSeenTimestamps"
    private func saveLastSeen() { UserDefaults.standard.set(lastSeenTimestamps, forKey: Self.storageKey) }
    private func loadLastSeen() {
        if let saved = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: Int] {
            lastSeenTimestamps = saved
        }
    }
}

// MARK: - Free functions & types (NO actor isolation)

struct DMPollEntity: Sendable {
    let npub: String
    let privKeyHex: String?
    let pubKeyHex: String?
    var hasKeys: Bool { privKeyHex != nil && pubKeyHex != nil }
}

struct DMPollResult: Sendable {
    let npub: String
    let newCount: Int
    let totalEvents: Int
    let latestTimestamp: Int
}

private struct PollTimeoutError: Error {}

/// Runs entirely off MainActor — free function guarantees no actor isolation.
/// All npubs are polled in parallel; each npub fans out across relays in parallel
/// (via NostrRelayService.fetchDMs), so npubs × relays run concurrently per cycle.
private func dmPollEntities(
    entities: [DMPollEntity],
    timestamps: [String: Int],
    cycle: Int
) async -> [DMPollResult] {
    let dmService = NostrDMService()
    let total = entities.count

    return await withTaskGroup(of: DMPollResult?.self) { group in
        for (index, entity) in entities.enumerated() {
            group.addTask {
                await dmPollSingleEntity(
                    entity: entity,
                    index: index,
                    total: total,
                    timestamps: timestamps,
                    dmService: dmService
                )
            }
        }
        var results: [DMPollResult] = []
        for await result in group {
            if let r = result { results.append(r) }
        }
        return results
    }
}

/// Poll a single npub — extracted so the task group stays clean.
private func dmPollSingleEntity(
    entity: DMPollEntity,
    index: Int,
    total: Int,
    timestamps: [String: Int],
    dmService: NostrDMService
) async -> DMPollResult? {
    if Task.isCancelled { return nil }

    let tag = "\(entity.npub.prefix(12))…"
    let label = "DM Poll [\(index+1)/\(total)]"

    guard let privKeyHex = entity.privKeyHex,
          let pubKeyHex = entity.pubKeyHex else {
        return nil
    }

    let since = timestamps[entity.npub]
    await MainActor.run {
        TrafficLogger.shared.log(.outbound, label: label, detail: "\(tag) relay fetch starting (since=\(since ?? 0))", npub: entity.npub)
    }

    let fetchResult: [String: [DecryptedDM]]
    let didTimeout: Bool
    do {
        fetchResult = try await withThrowingTimeout(seconds: 45) {
            await dmService.fetchConversations(
                privateKeyHex: privKeyHex,
                publicKeyHex: pubKeyHex,
                since: since
            )
        }
        didTimeout = false
    } catch {
        fetchResult = [:]
        didTimeout = true
    }

    if didTimeout {
        await MainActor.run {
            TrafficLogger.shared.log(.error, label: label, detail: "\(tag) timed out after 15s", npub: entity.npub)
        }
        return nil
    }

    if fetchResult.isEmpty {
        await MainActor.run {
            TrafficLogger.shared.log(.inbound, label: label, detail: "\(tag) 0 events", npub: entity.npub)
        }
        return nil
    }

    let lastSeen = timestamps[entity.npub] ?? 0
    var newCount = 0
    var latestTimestamp = lastSeen
    for (_, dms) in fetchResult {
        for dm in dms where !dm.isFromMe {
            let ts = Int(dm.createdAt.timeIntervalSince1970)
            if ts > lastSeen { newCount += 1 }
            latestTimestamp = max(latestTimestamp, ts)
        }
    }

    let totalEvents = fetchResult.values.flatMap { $0 }.count
    await MainActor.run {
        TrafficLogger.shared.log(.inbound, label: label, detail: "\(tag) \(totalEvents) events, \(newCount) new", npub: entity.npub)
    }

    return DMPollResult(npub: entity.npub, newCount: newCount, totalEvents: totalEvents, latestTimestamp: latestTimestamp)
}

/// Timeout that actually works: uses a detached timeout task + continuation.
/// Guaranteed no actor inheritance.
private func withThrowingTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @Sendable @escaping () async -> T
) async throws -> T {
    let result: T = try await withUnsafeThrowingContinuation { continuation in
        let state = TimeoutState()

        Task.detached {
            let value = await operation()
            if state.claim() {
                continuation.resume(returning: value)
            }
        }

        Task.detached {
            try? await Task.sleep(for: .seconds(seconds))
            if state.claim() {
                continuation.resume(throwing: PollTimeoutError())
            }
        }
    }
    return result
}

/// Thread-safe one-shot flag for timeout racing.
private final class TimeoutState: @unchecked Sendable {
    private var _claimed = false
    private let _lock = NSLock()
    func claim() -> Bool {
        _lock.lock()
        defer { _lock.unlock() }
        if _claimed { return false }
        _claimed = true
        return true
    }
}
