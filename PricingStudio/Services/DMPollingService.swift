import Foundation
import SwiftData

/// Polls Nostr relays for new DMs across all entities with stored nsec keys.
@MainActor @Observable
final class DMPollingService {
    static let shared = DMPollingService()

    private(set) var unreadCounts: [String: Int] = [:]
    private(set) var lastPollAt: Date?
    private(set) var pollCycle: Int = 0
    private(set) var subscriptionsActive: Bool = false
    private var lastSeenTimestamps: [String: Int] = [:]
    private var pollingTask: Task<Void, Never>?

    /// Poll interval: 10s normally, 60s when subscriptions are active (catch-up only).
    private var pollInterval: TimeInterval { subscriptionsActive ? 60 : 10 }

    private init() { loadLastSeen() }

    // MARK: - Public API

    func hasUnread(for npub: String) -> Bool { (unreadCounts[npub] ?? 0) > 0 }

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
                    // Use Task.detached to GUARANTEE no MainActor inheritance
                    let results = await Task.detached {
                        await dmPollEntities(
                            entities: entities,
                            timestamps: timestamps,
                            cycle: cycle
                        )
                    }.value

                    self.applyResults(results)
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

        // Wire event callback: decrypt incoming events and update unread counts
        subManager.onNewEvent = { [weak self] npub, event in
            guard let self else { return }
            // Attempt decryption using the npub's keys
            guard let privKeyHex = KeychainService.loadNsec(forNpub: npub)
                    .flatMap({ try? NostrKeyService.privateKeyHexFromNsec($0) }),
                  let pubKeyHex = try? NostrKeyService.publicKeyHexFromNpub(npub) else { return }

            Task.detached {
                let decrypted = await dmService.decryptEvent(
                    event, privateKeyHex: privKeyHex, publicKeyHex: pubKeyHex
                )
                if let dm = decrypted, !dm.isFromMe {
                    await MainActor.run {
                        var updated = self.unreadCounts
                        updated[npub] = (updated[npub] ?? 0) + 1
                        self.unreadCounts = updated
                        self.lastPollAt = Date()
                        TrafficLogger.shared.log(.inbound, label: "Sub Event",
                                                 detail: "\(npub.prefix(12))… new DM via subscription")
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
            }
            let lastSeen = lastSeenTimestamps[r.npub] ?? 0
            if r.latestTimestamp > lastSeen {
                lastSeenTimestamps[r.npub] = r.latestTimestamp
                saveLastSeen()
            }
        }
        unreadCounts = updated
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
        fetchResult = try await withThrowingTimeout(seconds: 15) {
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
