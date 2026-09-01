import DPYCAuthKit
import PricingStudioCore
import Foundation
import SwiftData
import UserNotifications

/// Polls Nostr relays for new DMs across all entities with stored nsec keys.
@MainActor @Observable
final class DMPollingService {
    static let shared = DMPollingService()

    /// Notification-group ("thread") identifier for ordinary DM banners. Kept
    /// distinct from the per-approval threads (see
    /// `ProofApprovalService.approvalThreadIdentifier`) so that dismissing a DM
    /// banner on the Apple Watch never sweeps away an actionable Approval
    /// Request sharing the app's default group (issue #83). All generic DM
    /// banners deliberately share this one thread: they already collapse per
    /// npub via their request identifier, and grouping them together under a
    /// dedicated DM group is exactly the desired shelf behavior.
    static let dmNotificationThreadIdentifier = "nostr-dm"

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

    /// Update the app icon badge with the total unread DM count. The badge is
    /// a notification surface, so muted identities are excluded — their unread
    /// still shows on the in-app sidebar envelope, just not on the app icon.
    private func updateAppBadge() {
        let total = unreadCounts
            .filter { NostrNotificationPreferences.isEnabled(npub: $0.key) }
            .values.reduce(0, +)
        UNUserNotificationCenter.current().setBadgeCount(total)
    }

    func startPolling(modelContext: ModelContext) {
        if pollingTask != nil { return }
        requestNotificationPermission()
        // RECEIVER side of the InboxSignal wake-up relay: make sure this
        // device holds the CloudKit subscription that turns another device's
        // marker write into a push here.
        Task { await InboxSignalService.shared.ensureSubscription() }
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

                // A roster built only at launch goes stale the moment an Operator
                // is adopted mid-session. Reconcile every cycle so a newly keyed
                // npub gets a live subscription without requiring a restart
                // (issue #148). subscribe()/unsubscribe() are idempotent.
                self.reconcileSubscriptions(entities: entities)

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
        let keyed = entities.filter(\.hasKeys).count
        guard keyed > 0 else {
            // The locked-iPhone drain lives or dies here: an empty roster means
            // the foreground never snapshotted it; readable-key count 0 means
            // the Keychain refused the nsecs (accessibility migration pending,
            // or device not yet unlocked since restart). Say which.
            TrafficLogger.shared.log(.error, label: "Drain",
                                     detail: "bailing: \(entities.count) npub\(entities.count == 1 ? "" : "s") in roster, 0 with readable keys")
            return
        }
        TrafficLogger.shared.log(.inbound, label: "Drain",
                                 detail: "\(entities.count) npub\(entities.count == 1 ? "" : "s") in roster, \(keyed) with readable keys")

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
        // The padlock wake push has served its purpose (APNs-priority wake);
        // leaving it in Notification Center is pure noise next to the real
        // banner the drain just posted.
        removeWakePushBanners()
    }

    /// Remove delivered CloudKit wake pushes (the 🔒 "Secure Courier message"
    /// alert) from Notification Center — on this device and, via mirroring,
    /// the watch. They exist only to win APNs priority delivery for the
    /// background wake; the drain's own banner is the one that matters.
    /// Remote pushes are the only push-triggered notifications this app
    /// receives visibly, so the trigger type is a sufficient filter.
    func removeWakePushBanners() {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let wakeIds = delivered
                .filter { $0.request.trigger is UNPushNotificationTrigger }
                .map(\.request.identifier)
            if !wakeIds.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: wakeIds)
            }
        }
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

            // SENDER side of the InboxSignal wake-up relay: a live gift wrap
            // for one of our npubs → marker record in the user's private
            // CloudKit DB so their other devices get a push and drain. Only
            // this live-subscription path publishes — the background drain
            // goes through dmPollEntities and never reaches this closure, so
            // the receiving device can't re-signal. Gate is on RECEIPT time
            // (wrap created_at is fuzzed up to 48h by NIP-59).
            if InboxSignalService.shouldSignal(
                kind: event.kind,
                receivedAt: Date(),
                subscriptionsStartedAt: self.subscriptionsStartedAt,
                alreadyNotified: self.notifiedStore.contains(npub: npub, eventId: event.id)
            ) {
                Task { await InboxSignalService.shared.publishSignal(eventId: event.id, npub: npub) }
            }

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
                                if let challenge = ProofApprovalService.classify(dm.content) {
                                    // One-tap-approvable proof challenge → the
                                    // actionable Wrist Approval banner.
                                    self.postApprovalNotification(npub: npub, dm: dm, challenge: challenge)
                                } else {
                                    // Redact courier payloads — don't leak secrets in notifications or logs
                                    let isCourier = dm.content.contains("@@@")
                                    let safePreview = isCourier ? "🔒 Secure Courier message" : String(dm.content.prefix(80))
                                    self.postLocalNotification(npub: npub, preview: safePreview, dm: dm)
                                }
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

        // Subscribe all entities with nsecs present at launch. Mid-session
        // additions are picked up by reconcileSubscriptions() in the poll loop.
        let entities = gatherEntities(modelContext: modelContext)
        reconcileSubscriptions(entities: entities)
    }

    /// Diff the live roster against the subscription set and open/close
    /// subscriptions so they match. Safe to call every poll cycle:
    /// `RelaySubscriptionManager.subscribe` / `unsubscribe` are idempotent.
    ///
    /// Without this, an Operator (or Patron/Authority) adopted after launch is
    /// returned by `gatherEntities` every cycle but never passed to
    /// `subscribe`, and the poll-path relay fetch is skipped while
    /// `subscriptionsActive` is true — so their DMs stay invisible until
    /// restart (issue #148).
    private func reconcileSubscriptions(entities: [DMPollEntity]) {
        let subManager = RelaySubscriptionManager.shared
        let keyed = entities.filter(\.hasKeys)
        let roster = Set(keyed.map(\.npub))
        let diff = SubscriptionRoster.diff(roster: roster, subscribed: subManager.subscribedNpubs)

        if !diff.toSubscribe.isEmpty {
            // Connections may not exist yet if launch had zero keyed entities.
            subManager.connectAll()
            for entity in keyed where diff.toSubscribe.contains(entity.npub) {
                if let pubKeyHex = entity.pubKeyHex, let privKeyHex = entity.privKeyHex {
                    subManager.subscribe(npub: entity.npub, pubkeyHex: pubKeyHex, privkeyHex: privKeyHex)
                }
            }
            if !subscriptionsActive {
                subscriptionsActive = true
                // Only stamp the start time the first time subscriptions come up
                // so mid-session additions don't re-open the historical-backfill
                // badge window for every already-subscribed npub.
                if subscriptionsStartedAt == nil {
                    subscriptionsStartedAt = Date()
                }
            }
            TrafficLogger.shared.log(
                .outbound,
                label: "Subscriptions",
                detail: "Reconcile +\(diff.toSubscribe.count) (now \(subManager.subscribedNpubs.count) npubs)"
            )
        }

        for npub in diff.toUnsubscribe {
            subManager.unsubscribe(npub: npub)
        }
        if !diff.toUnsubscribe.isEmpty {
            TrafficLogger.shared.log(
                .outbound,
                label: "Subscriptions",
                detail: "Reconcile -\(diff.toUnsubscribe.count) (now \(subManager.subscribedNpubs.count) npubs)"
            )
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
                let plainCount = postApprovalNotifications(npub: r.npub, freshEventIds: fresh, dms: r.newDMs)
                if plainCount > 0 {
                    postLocalNotification(npub: r.npub, preview: "\(plainCount) new message\(plainCount == 1 ? "" : "s")")
                }
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

    /// Post an actionable approval banner for every fresh proof challenge;
    /// return how many fresh events remain for the generic count banner —
    /// each event announces exactly once.
    private func postApprovalNotifications(npub: String, freshEventIds: [String], dms: [DecryptedDM]) -> Int {
        let freshSet = Set(freshEventIds)
        var remaining = freshEventIds.count
        for dm in dms where freshSet.contains(dm.rawEventId) {
            if let challenge = ProofApprovalService.classify(dm.content) {
                postApprovalNotification(npub: npub, dm: dm, challenge: challenge)
                remaining -= 1
            }
        }
        return remaining
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
                    let plainCount = postApprovalNotifications(npub: r.npub, freshEventIds: fresh, dms: r.newDMs)
                    if plainCount > 0 {
                        postLocalNotification(npub: r.npub, preview: "\(plainCount) new message\(plainCount == 1 ? "" : "s")")
                    }
                }
            }
            // Advance — or, on first sight, baseline — the watermark. The
            // baseline posts nothing by design (anti-backlog-dump), but it
            // must SAY so: an unlogged silent branch here once masqueraded
            // as a broken drain for a whole debugging session.
            if !hadWatermark {
                TrafficLogger.shared.log(.inbound, label: "Drain",
                                         detail: "\(r.npub.prefix(12))… baselined (first sight); \(r.newCount) backlog message\(r.newCount == 1 ? "" : "s") suppressed, next arrival notifies")
            }
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

    /// dpop_tokens we've already raised an approval banner for this process.
    /// The courier double-encodes each challenge (NIP-04 + NIP-44), so one
    /// logical approval arrives as two distinct Nostr events that share a
    /// dpop_token — the real unit of approval. The per-*event* NotifiedEventStore
    /// can't collapse them (different event ids), and iOS won't reliably coalesce
    /// two same-identifier `add()`s fired in the same tick. So we dedup by token
    /// in our own state, at the single choke point every posting path funnels
    /// through. In-memory is enough: tokens are short-lived (≈2h) and a re-notify
    /// after a process restart is harmless (the still-live challenge just reminds).
    private var postedApprovalTokens: Set<String> = []

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

    /// An InboxSignal CloudKit push already showed its own banner for this
    /// event — record it as announced so the drain that follows stays silent
    /// for it, and keep the unread count/badge in step with that banner.
    func recordRemoteAnnouncement(npub: String, eventId: String) {
        guard notificationMode == .deduplicated else { return }
        let fresh = notifiedStore.register(npub: npub, eventIds: [eventId])
        guard !fresh.isEmpty else { return }
        var updated = unreadCounts
        updated[npub] = (updated[npub] ?? 0) + 1
        unreadCounts = updated
        updateAppBadge()
    }

    /// Post the actionable Wrist Approval banner for a classified proof
    /// challenge. Approve/Reject live in the category (mirrored to the
    /// watch); everything the action handler needs travels in userInfo,
    /// precomputed here so the handler is dumb. Dedup is the CALLER's
    /// responsibility, same contract as postLocalNotification.
    private func postApprovalNotification(npub: String, dm: DecryptedDM, challenge: ProofApprovalService.ProofChallenge) {
        guard notificationMode != .off else { return }
        guard NostrNotificationPreferences.isEnabled(npub: npub) else { return }

        // One banner per dpop_token, deduped in our own state — see
        // postedApprovalTokens. The courier's twin encodings both land here;
        // the second insert fails and is suppressed. Record only tokens we
        // actually post, so a muted/off npub (returned above) never poisons the
        // set. Log both branches (event id only, never the token) so a live test
        // can distinguish "collapsed a twin" from "two genuinely different
        // approvals" without leaking the approval secret.
        guard postedApprovalTokens.insert(challenge.dpopToken).inserted else {
            TrafficLogger.shared.log(.inbound, label: "Approval Dedup",
                                     detail: "\(npub.prefix(12))… suppressed twin approval event=\(dm.rawEventId.prefix(8))…")
            return
        }
        TrafficLogger.shared.log(.inbound, label: "Approval Post",
                                 detail: "\(npub.prefix(12))… posted approval event=\(dm.rawEventId.prefix(8))…")

        let resolve = resolveDisplayName ?? { key in String(key.prefix(16)) + "…" }

        let approvalRequest = ProofApprovalService.ApprovalRequest(
            signerNpub: npub,
            replyToHex: dm.senderPubkeyHex,
            pinnedRelay: challenge.pinnedRelay,
            replyContent: ProofApprovalService.buildApprovalReply(challenge),
            eventId: dm.rawEventId
        )
        let content = Self.makeApprovalNotificationContent(
            body: "May I act as \(resolve(dm.recipientPubkeyHex))? — from \(resolve(dm.senderPubkeyHex))",
            request: approvalRequest,
            dpopToken: challenge.dpopToken
        )

        // Key on the dpop_token, not the transport event id: per the frozen
        // wire contract approval is per-dpop_token, so the token IS the unit of
        // approval. The courier double-encodes each challenge (NIP-04 + NIP-44)
        // for client compatibility, arriving as two distinct signed events that
        // both decode to the same token — keying on the token makes the second
        // REPLACE the first instead of stacking an identical banner. Distinct
        // approvals still carry distinct tokens, so real siblings never clobber.
        let request = UNNotificationRequest(
            identifier: "proof-\(challenge.dpopToken)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Post a banner. Dedup is the CALLER's responsibility via
    /// `notifiableEventIds(npub:eventIds:)`; this method only honors the off mode
    /// and renders. Keeping dedup out of here lets the unread count and the
    /// banner be gated by the same decision.
    private func postLocalNotification(npub: String, preview: String? = nil, dm: DecryptedDM? = nil) {
        guard notificationMode != .off else { return }
        guard NostrNotificationPreferences.isEnabled(npub: npub) else { return }
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

        let content = Self.makeDMNotificationContent(
            senderName: senderName,
            receiverName: receiverName,
            preview: preview
        )

        // One banner per npub: a stable identifier makes each new arrival
        // REPLACE the previous generic banner instead of piling another one
        // into Notification Center (the unread count carries the tally).
        // Approval banners keep per-event ids — each is independently
        // actionable and must not clobber a sibling.
        let request = UNNotificationRequest(
            identifier: "dm-\(npub)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Notification Content Builders

    /// Build the actionable Approval-Request banner. Static and pure so the
    /// Watch-critical thread isolation (issue #83) is unit-testable without a
    /// live `UNUserNotificationCenter`. Each approval declares its own
    /// per-dpop_token notification group so dismissing an unrelated DM banner
    /// on the watch cannot sweep it away.
    static func makeApprovalNotificationContent(
        body: String,
        request: ProofApprovalService.ApprovalRequest,
        dpopToken: String
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Approval requested"
        content.body = body
        content.sound = .default
        content.categoryIdentifier = ProofApprovalService.categoryId
        content.userInfo = request.userInfo
        content.threadIdentifier = ProofApprovalService.approvalThreadIdentifier(dpopToken: dpopToken)
        return content
    }

    /// Build the ordinary Nostr DM banner. Static and pure for the same
    /// reason as the approval builder; groups all DM banners under the
    /// dedicated DM thread, distinct from every approval thread (issue #83).
    static func makeDMNotificationContent(
        senderName: String,
        receiverName: String,
        preview: String?
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "New Nostr DM"
        content.body = "From \(senderName) to \(receiverName)"
        if let preview, !preview.isEmpty {
            content.body += "\n\(preview)"
        }
        content.sound = .default
        content.threadIdentifier = dmNotificationThreadIdentifier
        return content
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

// SubscriptionRoster lives in PricingStudioCore (host-free, unit-tested there).

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
    /// The decrypted DMs behind `newEventIds`, same order — lets the
    /// notification layer classify proof challenges and post actionable
    /// approval banners from the background drain.
    let newDMs: [DecryptedDM]
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
    var newDMs: [DecryptedDM] = []
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
                newDMs.append(dm)
            }
            latestTimestamp = max(latestTimestamp, ts)
        }
    }

    let totalEvents = fetchResult.values.flatMap { $0 }.count
    await MainActor.run {
        TrafficLogger.shared.log(.inbound, label: label, detail: "\(tag) \(totalEvents) events, \(newCount) new", npub: entity.npub)
    }

    return DMPollResult(npub: entity.npub, newCount: newCount, newEventIds: newEventIds, newDMs: newDMs, totalEvents: totalEvents, latestTimestamp: latestTimestamp)
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
