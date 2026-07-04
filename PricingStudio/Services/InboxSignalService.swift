import CloudKit
import DPYCAuthKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.tollbooth.dpyc.PricingStudio", category: "InboxSignal")

// MARK: - CloudKit Seams (unit-testable without iCloud)

protocol InboxSignalDatabase: Sendable {
    func save(_ record: CKRecord) async throws -> CKRecord
    func save(_ subscription: CKSubscription) async throws -> CKSubscription
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
/// a CKQuerySubscription push then wakes the user's other devices (the
/// pocketed iPhone), which run the existing background DM drain. No custom
/// server, no Operator involvement — strictly personal plumbing.
///
/// The marker carries only the Nostr event id and recipient npub — never
/// message content. The record name IS the event id, so concurrent writes
/// from two foregrounded devices dedup server-side (`serverRecordChanged`).
@MainActor
final class InboxSignalService {

    static let shared = InboxSignalService()

    static let recordType = "InboxSignal"
    static let subscriptionID = "inbox-signal-created-v1"
    static let subscriptionSavedKey = "inboxSignal.subscriptionSaved.v1"

    /// Live wraps arriving in the first moments of a subscription are the
    /// relay's historical backlog replay, not fresh traffic.
    static let settleWindowSeconds: TimeInterval = 30

    private let database: any InboxSignalDatabase
    private let account: any InboxSignalAccountProvider
    private let defaults: UserDefaults

    /// Per-process memo so relay replays don't hammer CloudKit.
    private var publishedEventIds: Set<String> = []
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

        let record = CKRecord(
            recordType: Self.recordType,
            recordID: CKRecord.ID(recordName: eventId)
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

    /// Ensure this device holds the CKQuerySubscription that turns another
    /// device's marker write into a push here. Idempotent; safe to call on
    /// every foreground start.
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

        let subscription = CKQuerySubscription(
            recordType: Self.recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: Self.subscriptionID,
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
            defaults.set(true, forKey: Self.subscriptionSavedKey)
            TrafficLogger.shared.log(.inbound, label: "InboxSignal", detail: "CloudKit subscription ensured")
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // A subscription with this stable ID already exists server-side.
            defaults.set(true, forKey: Self.subscriptionSavedKey)
            logger.info("InboxSignal subscription already present")
        } catch {
            TrafficLogger.shared.log(.error, label: "InboxSignal", detail: "subscription failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

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
