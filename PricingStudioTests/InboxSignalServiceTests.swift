import CloudKit
import XCTest
@testable import PricingStudio

// MARK: - Mocks

final class MockInboxSignalDatabase: InboxSignalDatabase, @unchecked Sendable {
    var savedRecords: [CKRecord] = []
    var savedSubscriptions: [CKSubscription] = []
    var savedZones: [CKRecordZone] = []
    var recordError: Error?
    var zoneError: Error?
    /// Scriptable per-subscription-type errors so the query→database
    /// fallback can be exercised independently.
    var querySubscriptionError: Error?
    var databaseSubscriptionError: Error?

    func save(_ record: CKRecord) async throws -> CKRecord {
        if let recordError { throw recordError }
        savedRecords.append(record)
        return record
    }

    func save(_ subscription: CKSubscription) async throws -> CKSubscription {
        if subscription is CKQuerySubscription, let querySubscriptionError {
            throw querySubscriptionError
        }
        if subscription is CKDatabaseSubscription, let databaseSubscriptionError {
            throw databaseSubscriptionError
        }
        savedSubscriptions.append(subscription)
        return subscription
    }

    func save(_ zone: CKRecordZone) async throws -> CKRecordZone {
        if let zoneError { throw zoneError }
        savedZones.append(zone)
        return zone
    }
}

final class MockAccountProvider: InboxSignalAccountProvider, @unchecked Sendable {
    var status: CKAccountStatus = .available
    var statusChecks = 0

    func accountStatus() async throws -> CKAccountStatus {
        statusChecks += 1
        return status
    }
}

// MARK: - Tests

@MainActor
final class InboxSignalServiceTests: XCTestCase {

    private var database = MockInboxSignalDatabase()
    private var account = MockAccountProvider()
    private var defaults: UserDefaults!
    private var service: InboxSignalService!

    private let eventId = String(repeating: "e", count: 64)
    private let npub = "npub1testpatron"

    override func setUp() {
        super.setUp()
        database = MockInboxSignalDatabase()
        account = MockAccountProvider()
        defaults = UserDefaults(suiteName: "InboxSignalServiceTests")!
        defaults.removePersistentDomain(forName: "InboxSignalServiceTests")
        service = InboxSignalService(database: database, account: account, defaults: defaults)
    }

    // MARK: Publish

    func testPublishSavesRecordInCustomZoneWithEventIdAsRecordName() async {
        await service.publishSignal(eventId: eventId, npub: npub)

        XCTAssertEqual(database.savedZones.map(\.zoneID), [InboxSignalService.zoneID],
                       "Markers live in a custom zone so the database-subscription fallback can see them")
        XCTAssertEqual(database.savedRecords.count, 1)
        let record = database.savedRecords[0]
        XCTAssertEqual(record.recordType, "InboxSignal")
        XCTAssertEqual(record.recordID.recordName, eventId, "Event id is the cross-device idempotency key")
        XCTAssertEqual(record.recordID.zoneID, InboxSignalService.zoneID)
        XCTAssertEqual(record["npub"] as? String, npub)
        XCTAssertNotNil(record["receivedAt"] as? Date)
    }

    func testZoneSavedOncePerProcess() async {
        await service.publishSignal(eventId: eventId, npub: npub)
        await service.publishSignal(eventId: String(repeating: "f", count: 64), npub: npub)

        XCTAssertEqual(database.savedZones.count, 1, "Zone ensure is memoized per process")
        XCTAssertEqual(database.savedRecords.count, 2)
    }

    func testZoneFailureSkipsRecordSave() async {
        database.zoneError = CKError(.serviceUnavailable)

        await service.publishSignal(eventId: eventId, npub: npub)
        XCTAssertTrue(database.savedRecords.isEmpty, "No zone, nowhere to write the marker")
    }

    func testServerRecordChangedIsTreatedAsDedupSuccess() async {
        database.recordError = CKError(.serverRecordChanged)

        await service.publishSignal(eventId: eventId, npub: npub)
        XCTAssertTrue(database.savedRecords.isEmpty)

        // The conflict memoized the id: a second publish makes no DB call.
        database.recordError = nil
        await service.publishSignal(eventId: eventId, npub: npub)
        XCTAssertTrue(database.savedRecords.isEmpty, "Conflict = another device already signaled; no retry")
    }

    func testRepublishSameEventIdSkipsDatabase() async {
        await service.publishSignal(eventId: eventId, npub: npub)
        await service.publishSignal(eventId: eventId, npub: npub)

        XCTAssertEqual(database.savedRecords.count, 1, "In-process memo caps relay replay chatter")
    }

    func testNoAccountSetsBackoffAndSkipsSave() async {
        account.status = .noAccount

        await service.publishSignal(eventId: eventId, npub: npub)
        XCTAssertTrue(database.savedRecords.isEmpty)

        // Inside the backoff window even the account check is skipped.
        let checksAfterFirst = account.statusChecks
        await service.publishSignal(eventId: String(repeating: "f", count: 64), npub: npub)
        XCTAssertEqual(account.statusChecks, checksAfterFirst, "Backoff suppresses further iCloud traffic")
        XCTAssertTrue(database.savedRecords.isEmpty)
    }

    // MARK: Subscription

    func testEnsureSubscriptionPrefersQuerySubscription() async {
        await service.ensureSubscription()

        XCTAssertEqual(database.savedSubscriptions.count, 1)
        let sub = try! XCTUnwrap(database.savedSubscriptions[0] as? CKQuerySubscription)
        XCTAssertEqual(sub.subscriptionID, "inbox-signal-created-v2")
        XCTAssertEqual(sub.recordType, "InboxSignal")
        XCTAssertEqual(sub.querySubscriptionOptions, [.firesOnRecordCreation])
        let info = try! XCTUnwrap(sub.notificationInfo)
        XCTAssertEqual(info.alertBody, "🔒 Secure Courier message", "Push carries no payload content")
        XCTAssertEqual(info.shouldSendMutableContent, true)
        XCTAssertEqual(info.shouldSendContentAvailable, true)
        XCTAssertEqual(info.desiredKeys, ["npub"])

        // Second call: flag set, no further saves.
        await service.ensureSubscription()
        XCTAssertEqual(database.savedSubscriptions.count, 1)
    }

    func testQueryRefusalFallsBackToSilentDatabaseSubscription() async {
        // Production's "attempting to create a subscription in a production
        // container" rejection surfaces as invalidArguments.
        database.querySubscriptionError = CKError(.invalidArguments)

        await service.ensureSubscription()

        XCTAssertEqual(database.savedSubscriptions.count, 1)
        let sub = try! XCTUnwrap(database.savedSubscriptions[0] as? CKDatabaseSubscription)
        XCTAssertEqual(sub.subscriptionID, "inbox-signal-db-v2")
        let info = try! XCTUnwrap(sub.notificationInfo)
        XCTAssertEqual(info.shouldSendContentAvailable, true)
        XCTAssertNil(info.alertBody, "Database-subscription pushes are silent wakes")

        // Fallback success also latches the flag.
        await service.ensureSubscription()
        XCTAssertEqual(database.savedSubscriptions.count, 1)
    }

    func testBothTiersRefusedLeavesFlagUnsetForRetry() async {
        database.querySubscriptionError = CKError(.invalidArguments)
        database.databaseSubscriptionError = CKError(.invalidArguments)

        await service.ensureSubscription()
        XCTAssertTrue(database.savedSubscriptions.isEmpty)

        // Next foreground start retries from the top.
        database.querySubscriptionError = nil
        await service.ensureSubscription()
        XCTAssertEqual(database.savedSubscriptions.count, 1)
        XCTAssertTrue(database.savedSubscriptions[0] is CKQuerySubscription)
    }

    func testAlreadyPresentSubscriptionCountsAsEnsured() async {
        database.querySubscriptionError = CKError(.serverRejectedRequest)

        await service.ensureSubscription()
        XCTAssertTrue(database.savedSubscriptions.isEmpty, "Server already holds the stable-ID subscription")

        // Flag latched: no further attempts.
        database.querySubscriptionError = nil
        await service.ensureSubscription()
        XCTAssertTrue(database.savedSubscriptions.isEmpty)
    }

    func testHandlerRecognizesBothSubscriptionIDs() {
        XCTAssertTrue(InboxSignalService.knownSubscriptionIDs.contains("inbox-signal-created-v2"))
        XCTAssertTrue(InboxSignalService.knownSubscriptionIDs.contains("inbox-signal-db-v2"))
        XCTAssertFalse(InboxSignalService.knownSubscriptionIDs.contains("inbox-signal-created-v1"),
                       "The v1 TRUEPREDICATE subscription never existed server-side")
    }

    // MARK: Signal Gate

    func testShouldSignalTruthTable() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let fresh = start.addingTimeInterval(120)      // past the settle window
        let settling = start.addingTimeInterval(5)     // inside the settle window
        let giftWrap = 1059
        let nip04 = 4

        // Live, unseen gift wrap after settle → signal.
        XCTAssertTrue(InboxSignalService.shouldSignal(
            kind: giftWrap, receivedAt: fresh, subscriptionsStartedAt: start, alreadyNotified: false))

        // Non-1059 kinds never signal.
        XCTAssertFalse(InboxSignalService.shouldSignal(
            kind: nip04, receivedAt: fresh, subscriptionsStartedAt: start, alreadyNotified: false))

        // Backlog dump right after subscribing → no signal.
        XCTAssertFalse(InboxSignalService.shouldSignal(
            kind: giftWrap, receivedAt: settling, subscriptionsStartedAt: start, alreadyNotified: false))

        // Already announced on this device → no signal.
        XCTAssertFalse(InboxSignalService.shouldSignal(
            kind: giftWrap, receivedAt: fresh, subscriptionsStartedAt: start, alreadyNotified: true))

        // No subscription epoch (shouldn't happen live) → no signal.
        XCTAssertFalse(InboxSignalService.shouldSignal(
            kind: giftWrap, receivedAt: fresh, subscriptionsStartedAt: nil, alreadyNotified: false))
    }

    /// NIP-59 fuzzes wrap `created_at` up to 48h into the past. The gate uses
    /// receipt time, so a heavily fuzzed but just-received wrap still signals.
    func testFuzzedCreatedAtIsIrrelevantToGate() {
        let start = Date()
        let receivedNow = start.addingTimeInterval(120)
        // (No created_at parameter exists on the gate — this documents intent.)
        XCTAssertTrue(InboxSignalService.shouldSignal(
            kind: 1059, receivedAt: receivedNow, subscriptionsStartedAt: start, alreadyNotified: false))
    }
}
