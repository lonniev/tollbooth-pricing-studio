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
        // Reading only resets the unread badge and advances the watermark. The
        // announced-event ledger is deliberately NOT cleared here: it is a
        // permanent (bounded, oldest-evicted) record of "a banner already fired
        // for this event ID." Relays replay their backlog on every reconnect/poll,
        // and the subscription path has no watermark gate — so the ledger is the
        // ONLY guard between a re-delivered, already-read DM and a duplicate
        // banner. Wiping it on read was the re-notification leak: a read message
        // got re-announced the moment a relay replayed it, which bumped unread and
        // re-triggered markRead in a loop.
        saveLastSeen()
        updateAppBadge()
    }

    /// Update the app icon badge with the total unread DM count.
    private func updateAppBadge() {
        let total = unreadCounts.values.reduce(0, +)
        UNUserNotificationCenter.current().setBadgeCount(total)
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

    /// One-shot drain for the background DM-refresh task (BGAppRefreshTask).
    ///
    /// Runs a single fetch cycle via the poll path — the background has no live
    /// websocket subscriptions — and posts notifications for anything newer than
    /// the persisted last-seen timestamp. Unlike the foreground first poll
    /// (which only baselines timestamps to avoid flagging the existing backlog),
    /// this DELIBERATELY notifies: surfacing new DMs while the app is suspended
    /// is the whole point.
    ///
    /// Crucially, this path NEVER touches SwiftData. iOS can launch the app
    /// directly into the background to service the refresh task, before any
    /// scene — and thus before the CloudKit-backed ModelContainer — exists.
    /// Constructing that container on a headless background thread traps inside
    /// SwiftData (EXC_BREAKPOINT). So the roster comes from a UserDefaults
    /// snapshot written by the foreground; nsecs come from the Keychain.
    func runBackgroundDrain() async {
        let entities = backgroundEntities()
        guard entities.contains(where: { $0.hasKeys }) else { return }

        pollCycle += 1
        let cycle = pollCycle
        let timestamps = lastSeenTimestamps
        // iOS grants a BGAppRefreshTask only ~30s. Cap the whole drain well
        // under that so it completes and signals the OS cleanly, instead of
        // racing the per-entity 45s fetch timeout and getting watchdog-killed.
        let results: [DMPollResult] = await Task.detached {
            (try? await withThrowingTimeout(seconds: 20) {
                await dmPollEntities(entities: entities, timestamps: timestamps, cycle: cycle)
            }) ?? []
        }.value
        applyBackgroundResults(results, priorWatermarks: timestamps)
        lastPollAt = Date()
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
                        // A self-notice (sender == recipient == this entity's own
                        // npub) is a legitimate inbound alert — e.g. an Operator
                        // /sub-Authority's own low-certification-balance reminder
                        // (SDK _dun_self_low_cert_balance). It carries isFromMe ==
                        // true, so the normal "don't notify my own sent messages"
                        // gate would swallow it. Let it through; ordinary messages
                        // we sent to *others* stay suppressed.
                        let isSelfNotice = dm.senderPubkeyHex == pubKeyHex
                            && dm.recipientPubkeyHex == pubKeyHex
                        if (!dm.isFromMe || isSelfNotice) && isNew {
                            // Dedup BEFORE touching unread or posting. Relays replay
                            // their backlog on every (re)connect, so the same event
                            // arrives repeatedly; the durable store collapses those to
                            // one announcement and keeps the unread count honest.
                            // NOTE: delivery happened above via onLiveDM and is NOT
                            // gated by this — only the badge/banner are.
                            let fresh = self.notifiableEventIds(npub: npub, eventIds: [dm.rawEventId])
                            if !fresh.isEmpty {
                                var updated = self.unreadCounts
                                updated[npub] = (updated[npub] ?? 0) + 1
                                self.unreadCounts = updated
                                self.updateAppBadge()
                                // Redact courier payloads — don't leak secrets in notifications or logs
                                let isCourier = dm.content.contains("@@@")
                                let safePreview = isCourier ? "🔒 Secure Courier message" : String(dm.content.prefix(80))
                                self.postLocalNotification(npub: npub, preview: safePreview, dm: dm)
                            }
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

        // Snapshot the roster so the background refresh task can rebuild these
        // entities WITHOUT touching SwiftData (see backgroundEntities()).
        UserDefaults.standard.set(allNpubs, forKey: Self.knownNpubsKey)

        return entitiesForNpubs(allNpubs)
    }

    /// Build poll entities for the background refresh task WITHOUT touching
    /// SwiftData — reads the roster from the foreground's UserDefaults snapshot.
    /// See runBackgroundDrain() for why a ModelContainer must not be built here.
    private func backgroundEntities() -> [DMPollEntity] {
        let npubs = (UserDefaults.standard.array(forKey: Self.knownNpubsKey) as? [String]) ?? []
        return entitiesForNpubs(npubs)
    }

    /// Map npubs → poll entities by pulling each nsec from the Keychain.
    /// Keychain + key derivation only — no SwiftData, safe off any thread.
    private func entitiesForNpubs(_ npubs: [String]) -> [DMPollEntity] {
        npubs.map { npub in
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
            // Dedup per-message against the durable store so a re-fetch of the
            // same events never re-announces (the watermark is the first guard;
            // this is the second, and it survives processes).
            let fresh = notifiableEventIds(npub: r.npub, eventIds: r.newEventIds)
            if !fresh.isEmpty {
                updated[r.npub] = (updated[r.npub] ?? 0) + fresh.count
                postLocalNotification(npub: r.npub, preview: "\(fresh.count) new message\(fresh.count == 1 ? "" : "s")")
            }
            let lastSeen = lastSeenTimestamps[r.npub] ?? 0
            if r.latestTimestamp > lastSeen {
                lastSeenTimestamps[r.npub] = r.latestTimestamp
                saveLastSeen()
            }
        }
        unreadCounts = updated
        updateAppBadge()
    }

    /// Apply a background-drain result set so notifications feel like *arrivals*,
    /// not a recap of the relay backlog. Differs from `applyResults` in two ways:
    ///
    ///   1. An npub we have no watermark for yet is BASELINED silently — we
    ///      record where the conversation stands but post nothing, so a cold
    ///      start (or a lost watermark) never dumps the existing backlog as
    ///      "new." Only npubs with an established watermark can notify.
    ///   2. The advanced watermark is flushed to disk synchronously. Each
    ///      background wake is a fresh, short-lived process that iOS suspends the
    ///      moment it finishes; without forcing the write, consecutive wakes load
    ///      the stale watermark and re-announce the same messages every time.
    private func applyBackgroundResults(_ results: [DMPollResult], priorWatermarks: [String: Int]) {
        var updatedUnread = unreadCounts
        for r in results {
            let hadWatermark = priorWatermarks[r.npub] != nil
            if hadWatermark {
                // Per-message dedup via the durable store, on top of the
                // first-sight baseline gate. The store persists across these
                // short-lived background processes, so consecutive wakes don't
                // re-announce the same DM even before the watermark advances.
                let fresh = notifiableEventIds(npub: r.npub, eventIds: r.newEventIds)
                if !fresh.isEmpty {
                    updatedUnread[r.npub] = (updatedUnread[r.npub] ?? 0) + fresh.count
                    postLocalNotification(npub: r.npub, preview: "\(fresh.count) new message\(fresh.count == 1 ? "" : "s")")
                }
            }
            // Advance — or, on first sight, silently baseline — the watermark.
            let lastSeen = lastSeenTimestamps[r.npub] ?? 0
            if r.latestTimestamp > lastSeen {
                lastSeenTimestamps[r.npub] = r.latestTimestamp
            }
        }
        unreadCounts = updatedUnread
        updateAppBadge()
        saveLastSeen()
        // Force the watermark AND the notified-event store to disk before iOS
        // suspends this background process, so the next wake resumes from here
        // instead of re-announcing the backlog.
        UserDefaults.standard.synchronize()
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

    /// Durable, per-npub record of DM event IDs already announced. Replaces the
    /// old 5-minute in-memory window, which forgot any DM left unread longer than
    /// five minutes and evaporated on every app relaunch / background process —
    /// so relay backlog replays re-announced the same unread DM repeatedly. An
    /// event now stays "seen" permanently — bounded to the most-recent
    /// `maxPerNpub` IDs per npub (oldest evicted), persisted across processes.
    /// Reading a conversation does NOT forget its announcements; that is what
    /// stops a replayed, already-read DM from re-banner-ing.
    private var notifiedStore = NotifiedEventStore()

    /// Which of `eventIds` should produce a notification now, honoring the mode.
    /// Dedup lives HERE — upstream of postLocalNotification — so the badge count
    /// and the banner stay in lock-step and a replayed event increments neither.
    ///   • .off         → notify for none
    ///   • .allRelays   → notify for every delivery (no dedup, no recording)
    ///   • .deduplicated→ record + return only the not-yet-seen IDs
    private func notifiableEventIds(npub: String, eventIds: [String]) -> [String] {
        switch notificationMode {
        case .off: return []
        case .allRelays: return eventIds
        case .deduplicated: return notifiedStore.register(npub: npub, eventIds: eventIds)
        }
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Post a banner. Dedup is the CALLER's responsibility via
    /// `notifiableEventIds(npub:eventIds:)`; this method only honors the off mode
    /// and renders. Keeping dedup out of here lets the unread count and the
    /// banner be gated by the same decision.
    private func postLocalNotification(npub: String, preview: String? = nil, dm: DecryptedDM? = nil) {
        guard notificationMode != .off else { return }
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
    private static let knownNpubsKey = "dm.knownNpubs"
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
    /// Raw Nostr event IDs of the new (inbound, past-watermark) messages, in
    /// timestamp-encounter order. Lets the notification layer dedup per-message
    /// against the durable store rather than re-announcing by count alone.
    let newEventIds: [String]
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
    var newEventIds: [String] = []
    var latestTimestamp = lastSeen
    for (_, dms) in fetchResult {
        // `!dm.isFromMe` excludes our own sent-to-others messages; a self-notice
        // (sender == recipient == our own npub, e.g. the SDK's low-cert-balance
        // reminder) is a real inbound alert and must still count/announce.
        for dm in dms where !dm.isFromMe
            || (dm.senderPubkeyHex == pubKeyHex && dm.recipientPubkeyHex == pubKeyHex) {
            let ts = Int(dm.createdAt.timeIntervalSince1970)
            if ts > lastSeen {
                newCount += 1
                newEventIds.append(dm.rawEventId)
            }
            latestTimestamp = max(latestTimestamp, ts)
        }
    }

    let totalEvents = fetchResult.values.flatMap { $0 }.count
    await MainActor.run {
        TrafficLogger.shared.log(.inbound, label: label, detail: "\(tag) \(totalEvents) events, \(newCount) new", npub: entity.npub)
    }

    return DMPollResult(npub: entity.npub, newCount: newCount, newEventIds: newEventIds, totalEvents: totalEvents, latestTimestamp: latestTimestamp)
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

/// Durable, per-npub record of DM event IDs that have already produced a
/// notification.
///
/// Replaces the previous 5-minute in-memory dedup window, which had two holes:
/// it forgot any DM left unread longer than five minutes, and it evaporated on
/// every app relaunch and background-refresh process (each a fresh process).
/// Relays replay their backlog on every (re)connect, so those holes meant the
/// same unread DM got re-announced again and again.
///
/// Semantics: an event ID stays "seen" permanently once a banner has fired for
/// it — bounded to the most-recent `maxPerNpub` IDs per npub (oldest evicted),
/// persisted across processes via UserDefaults. There is no forget-on-read path:
/// reading a conversation resets its unread badge but must not re-open the door
/// to a replayed DM re-announcing. Per-npub, so one npub's ledger never affects
/// another's. Lives on the MainActor-isolated DMPollingService; not Sendable.
struct NotifiedEventStore {
    private let defaults: UserDefaults
    private let key: String
    private let maxPerNpub: Int
    private var ids: [String: [String]]

    init(defaults: UserDefaults = .standard,
         key: String = "dm.notifiedEventIds",
         maxPerNpub: Int = 500) {
        self.defaults = defaults
        self.key = key
        self.maxPerNpub = maxPerNpub
        self.ids = (defaults.dictionary(forKey: key) as? [String: [String]]) ?? [:]
    }

    /// Record `eventIds` as announced for `npub`; return the subset that was NOT
    /// already known — i.e. the IDs that should produce a notification now.
    /// Idempotent: replaying the same IDs (relay backlog) returns []. Dedups
    /// within the batch too. Oldest IDs are evicted past `maxPerNpub` to bound
    /// UserDefaults growth.
    mutating func register(npub: String, eventIds: [String]) -> [String] {
        guard !eventIds.isEmpty else { return [] }
        var list = ids[npub] ?? []
        var seen = Set(list)
        var fresh: [String] = []
        for id in eventIds where seen.insert(id).inserted {
            fresh.append(id)
        }
        guard !fresh.isEmpty else { return [] }
        list.append(contentsOf: fresh)
        if list.count > maxPerNpub {
            list.removeFirst(list.count - maxPerNpub)
        }
        ids[npub] = list
        persist()
        return fresh
    }

    func contains(npub: String, eventId: String) -> Bool {
        ids[npub]?.contains(eventId) ?? false
    }

    private func persist() {
        defaults.set(ids, forKey: key)
    }
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
