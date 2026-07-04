import CloudKit
import DPYCAuthKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.tollbooth.dpyc.PricingStudio", category: "InboxSignal")

// MARK: - CloudKit Seams (unit-testable without iCloud)

protocol InboxSignalDatabase: Sendable {
    func save(_ record: CKRecord) async throws -> CKRecord
    func save(_ subscription: CKSubscription) async throws -> CKSubscription
    func save(_ zone: CKRecordZone) async throws -> CKRecordZone
    @discardableResult
    func deleteSubscription(withID subscriptionID: CKSubscription.ID) async throws -> CKSubscription.ID
}

extension CKDatabase: InboxSignalDatabase {}

protocol InboxSignalAccountProvider: Sendable {
    func accountStatus() async throws -> CKAccountStatus
}

extension CKContainer: InboxSignalAccountProvider {}

// MARK: - Inbox Signal Service

/// The wake-up relay between the user's OWN devices, over their private
/// CloudKit database. Whichever device has Studio foregrounded (live relay
/// sockets) writes a tiny marker record when a kind-1059 gift wrap arrives;
/// a CloudKit subscription push then wakes the user's other devices (the
/// pocketed iPhone), which run the existing background DM drain. No custom
/// server, no Operator involvement — strictly personal plumbing.
///
/// The marker carries only the Nostr event id and recipient npub — never
/// message content. The record name IS the event id, so concurrent writes
/// from two foregrounded devices dedup server-side (`serverRecordChanged`).
///
/// Markers live in a custom record zone so that BOTH subscription styles can
/// see them: a CKQuerySubscription (nil zone = database-wide) and the
/// CKDatabaseSubscription fallback (custom zones only, by CloudKit rule).
///
/// Three-tier subscription ladder. Production rejects runtime
/// CKQuerySubscription creation when the subscription type was never
/// registered from a development-signed build ("attempting to create a
/// subscription in a production container", FB22867235) — and this app has
/// only ever shipped through TestFlight. And silent (content-available)
/// pushes are throttled/deferred at iOS's whim, so an alert push matters.
/// The ladder, best first:
///   1. CKQuerySubscription — alert push with record details.
///   2. CKRecordZoneSubscription on InboxSignalZone — alert push, no record
///      details, but zone subscriptions are data-scoped, not schema-scoped,
///      so Production allows runtime creation.
///   3. CKDatabaseSubscription — silent wake, last resort; the drain it
///      triggers posts the real DM notification locally.
@MainActor
final class InboxSignalService {

    static let shared = InboxSignalService()

    static let recordType = "InboxSignal"
    static let zoneID = CKRecordZone.ID(zoneName: "InboxSignalZone", ownerName: CKCurrentUserDefaultName)
    static let querySubscriptionID = "inbox-signal-created-v2"
    static let zoneSubscriptionID = "inbox-signal-zone-v3"
    static let databaseSubscriptionID = "inbox-signal-db-v3"
    static let knownSubscriptionIDs: Set<String> = [
        querySubscriptionID, zoneSubscriptionID, databaseSubscriptionID,
    ]
    /// Superseded subscriptions to clean up once a current tier is ensured,
    /// so devices don't receive double pushes.
    static let retiredSubscriptionIDs = ["inbox-signal-db-v2"]
    static let subscriptionSavedKey = "inboxSignal.subscriptionSaved.v3"

    /// Live wraps arriving in the first moments of a subscription are the
    /// relay's historical backlog replay, not fresh traffic.
    static let settleWindowSeconds: TimeInterval = 30

    private let database: any InboxSignalDatabase
    private let account: any InboxSignalAccountProvider
    private let defaults: UserDefaults

    /// Per-process memo so relay replays don't hammer CloudKit.
    private var publishedEventIds: Set<String> = []
    /// Zone saves are idempotent; once per process is plenty.
    private var zoneEnsured = false
    /// Backoff horizon when iCloud is unavailable or rate-limits us.
    private var unavailableUntil: Date?

    private init() {
        let container = CKContainer(identifier: "iCloud.com.tollbooth.dpyc.PricingStudio")
        self.database = container.privateCloudDatabase
        self.account = container
        self.defaults = .standard
    }

    /// Test seam.
    init(
        database: any InboxSignalDatabase,
        account: any InboxSignalAccountProvider,
        defaults: UserDefaults = .standard
    ) {
        self.database = database
        self.account = account
        self.defaults = defaults
    }

    // MARK: - Signal Gate

    /// Whether a live-subscription event should publish a wake-up marker.
    ///
    /// Gates on RECEIPT time, never `event.created_at` — NIP-59 fuzzes wrap
    /// timestamps up to 48h into the past, so a created_at gate would drop
    /// genuinely fresh wraps. The settle window separates the initial REQ
    /// backlog dump from live arrivals.
    static func shouldSignal(
        kind: Int,
        receivedAt: Date,
        subscriptionsStartedAt: Date?,
        alreadyNotified: Bool
    ) -> Bool {
        guard kind == NostrEventKind.giftWrap.rawValue else { return false }
        guard !alreadyNotified else { return false }
        guard let startedAt = subscriptionsStartedAt else { return false }
        return receivedAt > startedAt.addingTimeInterval(settleWindowSeconds)
    }

    // MARK: - Publish (SENDER side)

    /// Write the wake-up marker for a freshly received gift wrap.
    /// Never throws into the DM path — failures log and back off.
    func publishSignal(eventId: String, npub: String) async {
        guard !publishedEventIds.contains(eventId) else { return }
        if let until = unavailableUntil, Date() < until {
            TrafficLogger.shared.log(.error, label: "InboxSignal", detail: "publish skipped: iCloud backoff until \(until.formatted(date: .omitted, time: .standard))", npub: npub)
            return
        }

        guard await accountAvailable() else {
            TrafficLogger.shared.log(.error, label: "InboxSignal", detail: "publish skipped: iCloud account unavailable", npub: npub)
            return
        }

        guard await ensureZone() else {
            TrafficLogger.shared.log(.error, label: "InboxSignal", detail: "publish skipped: zone unavailable", npub: npub)
            return
        }

        let record = CKRecord(
            recordType: Self.recordType,
            recordID: CKRecord.ID(recordName: eventId, zoneID: Self.zoneID)
        )
        record["npub"] = npub
        record["receivedAt"] = Date()

        do {
            _ = try await database.save(record)
            publishedEventIds.insert(eventId)
            TrafficLogger.shared.log(.outbound, label: "InboxSignal", detail: "publish ok \(eventId.prefix(8))", npub: npub)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Another device won the race — the wake-up is already on its way.
            publishedEventIds.insert(eventId)
            logger.info("InboxSignal \(eventId.prefix(8)) already published by another device")
        } catch let error as CKError {
            applyBackoff(for: error)
            TrafficLogger.shared.log(.error, label: "InboxSignal", detail: "publish failed: \(error.localizedDescription)", npub: npub)
        } catch {
            TrafficLogger.shared.log(.error, label: "InboxSignal", detail: "publish failed: \(error.localizedDescription)", npub: npub)
        }
    }

    // MARK: - Subscription (RECEIVER side)

    /// Ensure this device holds a CloudKit subscription that turns another
    /// device's marker write into a push here. Idempotent; safe to call on
    /// every foreground start. Prefers the alert-carrying query subscription;
    /// falls back to a silent database subscription when Production refuses
    /// runtime query-subscription creation (see class doc).
    func ensureSubscription() async {
        guard !defaults.bool(forKey: Self.subscriptionSavedKey) else { return }
        if let until = unavailableUntil, Date() < until {
            TrafficLogger.shared.log(.error, label: "InboxSignal", detail: "subscription deferred: iCloud backoff")
            return
        }

        guard await accountAvailable() else {
            TrafficLogger.shared.log(.error, label: "InboxSignal", detail: "subscription deferred: iCloud account unavailable")
            return
        }

        guard await ensureZone() else {
            TrafficLogger.shared.log(.error, label: "InboxSignal", detail: "subscription deferred: zone unavailable")
            return
        }

        var ensured = await saveQuerySubscription()
        if !ensured {
            ensured = await saveZoneSubscription()
        }
        if !ensured {
            ensured = await saveDatabaseSubscription()
        }
        if ensured {
            defaults.set(true, forKey: Self.subscriptionSavedKey)
            await retireSupersededSubscriptions()
        }
    }

    /// Tier 1: alert push with the courier-redaction banner.
    private func saveQuerySubscription() async -> Bool {
        let subscription = CKQuerySubscription(
            recordType: Self.recordType,
            // A concrete field predicate, not TRUEPREDICATE — Production has
            // historically refused TRUEPREDICATE query subscriptions. Always
            // true in practice; requires a Queryable index on receivedAt.
            predicate: NSPredicate(format: "receivedAt > %@", Date.distantPast as NSDate),
            subscriptionID: Self.querySubscriptionID,
            options: [.firesOnRecordCreation]
        )
        let info = CKSubscription.NotificationInfo()
        // Courier-redaction style: the push itself never carries content.
        info.alertBody = "🔒 Secure Courier message"
        info.shouldSendMutableContent = true    // future NSE rewrite
        info.shouldSendContentAvailable = true  // background drain wake
        info.soundName = "default"
        info.desiredKeys = ["npub"]
        subscription.notificationInfo = info

        do {
            _ = try await database.save(subscription as CKSubscription)
            TrafficLogger.shared.log(.inbound, label: "InboxSignal", detail: "CloudKit query subscription ensured")
            return true
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // A subscription with this stable ID already exists server-side.
            logger.info("InboxSignal query subscription already present")
            return true
        } catch {
            TrafficLogger.shared.log(.error, label: "InboxSignal", detail: "query subscription refused (\(error.localizedDescription)); falling back to database subscription")
            return false
        }
    }

    /// Tier 2: alert push scoped to the marker zone. Zone subscriptions are
    /// data-scoped (the zone is ours alone), so Production permits runtime
    /// creation where it refuses query subscriptions. The push carries no
    /// record details — the drain announces the actual DM.
    private func saveZoneSubscription() async -> Bool {
        let subscription = CKRecordZoneSubscription(
            zoneID: Self.zoneID,
            subscriptionID: Self.zoneSubscriptionID
        )
        let info = CKSubscription.NotificationInfo()
        // Courier-redaction style: the push itself never carries content.
        info.alertBody = "🔒 Secure Courier message"
        info.shouldSendMutableContent = true    // future NSE rewrite
        info.shouldSendContentAvailable = true  // background drain wake
        info.soundName = "default"
        subscription.notificationInfo = info

        do {
            _ = try await database.save(subscription as CKSubscription)
            TrafficLogger.shared.log(.inbound, label: "InboxSignal", detail: "CloudKit zone subscription ensured (alert)")
            return true
        } catch let error as CKError where error.code == .serverRejectedRequest {
            logger.info("InboxSignal zone subscription already present")
            return true
        } catch {
            TrafficLogger.shared.log(.error, label: "InboxSignal", detail: "zone subscription refused (\(error.localizedDescription)); falling back to database subscription")
            return false
        }
    }

    /// Tier 3: silent wake. The drain it triggers posts the real DM
    /// notification, so the user still gets a banner — just authored locally.
    private func saveDatabaseSubscription() async -> Bool {
        let subscription = CKDatabaseSubscription(subscriptionID: Self.databaseSubscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info

        do {
            _ = try await database.save(subscription as CKSubscription)
            TrafficLogger.shared.log(.inbound, label: "InboxSignal", detail: "CloudKit database subscription ensured (silent wake)")
            return true
        } catch let error as CKError where error.code == .serverRejectedRequest {
            logger.info("InboxSignal database subscription already present")
            return true
        } catch {
            TrafficLogger.shared.log(.error, label: "InboxSignal", detail: "database subscription failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Best-effort cleanup of subscriptions from earlier ladder versions so
    /// devices don't receive double pushes. "Not found" is the happy path.
    private func retireSupersededSubscriptions() async {
        for id in Self.retiredSubscriptionIDs {
            do {
                try await database.deleteSubscription(withID: id)
                logger.info("InboxSignal retired superseded subscription \(id)")
            } catch {
                // Already gone (or transient) — nothing to do.
            }
        }
    }

    // MARK: - Helpers

    /// Zones are data, not schema — runtime creation is allowed in Production
    /// and re-saving an existing zone succeeds.
    private func ensureZone() async -> Bool {
        guard !zoneEnsured else { return true }
        do {
            _ = try await database.save(CKRecordZone(zoneID: Self.zoneID))
            zoneEnsured = true
            return true
        } catch let error as CKError {
            applyBackoff(for: error)
            TrafficLogger.shared.log(.error, label: "InboxSignal", detail: "zone save failed: \(error.localizedDescription)")
            return false
        } catch {
            TrafficLogger.shared.log(.error, label: "InboxSignal", detail: "zone save failed: \(error.localizedDescription)")
            return false
        }
    }

    private func accountAvailable() async -> Bool {
        do {
            let status = try await account.accountStatus()
            guard status == .available else {
                unavailableUntil = Date().addingTimeInterval(15 * 60)
                TrafficLogger.shared.log(.error, label: "InboxSignal", detail: "iCloud accountStatus=\(status.rawValue) (1=noAccount 2=restricted 3=noneDetermined 4=temporarilyUnavailable); backing off 15m")
                return false
            }
            return true
        } catch {
            unavailableUntil = Date().addingTimeInterval(15 * 60)
            TrafficLogger.shared.log(.error, label: "InboxSignal", detail: "iCloud account check failed: \(error.localizedDescription); backing off 15m")
            return false
        }
    }

    private func applyBackoff(for error: CKError) {
        switch error.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
            let retryAfter = error.retryAfterSeconds ?? 60
            unavailableUntil = Date().addingTimeInterval(retryAfter)
        default:
            break
        }
    }
}
