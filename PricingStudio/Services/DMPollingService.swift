import Foundation
import OSLog
import SwiftData

private let logger = Logger(subsystem: "com.tollbooth.dpyc.PricingStudio", category: "DMPolling")

/// Polls Nostr relays for new DMs across all entities with stored nsec keys.
///
/// Tracks per-npub unread counts and persists "last seen" timestamps in UserDefaults.
/// Designed as a singleton; start polling once the model context is available.
@MainActor @Observable
final class DMPollingService {
    static let shared = DMPollingService()

    private(set) var unreadCounts: [String: Int] = [:]        // npub -> unread count
    private(set) var lastPollAt: Date?                         // set after each poll cycle completes
    private var lastSeenTimestamps: [String: Int] = [:]       // npub -> latest seen event timestamp
    private var pollingTask: Task<Void, Never>?
    private let dmService = NostrDMService()
    private let pollInterval: TimeInterval = 10

    private init() {
        loadLastSeen()
    }

    // MARK: - Public API

    func hasUnread(for npub: String) -> Bool {
        (unreadCounts[npub] ?? 0) > 0
    }

    func unreadCount(for npub: String) -> Int {
        unreadCounts[npub] ?? 0
    }

    func markRead(npub: String) {
        unreadCounts[npub] = 0
        lastSeenTimestamps[npub] = Int(Date().timeIntervalSince1970)
        saveLastSeen()
    }

    func startPolling(modelContext: ModelContext) {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollAll(modelContext: modelContext)
                try? await Task.sleep(for: .seconds(self?.pollInterval ?? 60))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Polling

    private func pollAll(modelContext: ModelContext) async {
        defer { lastPollAt = Date() }

        let operators = (try? modelContext.fetch(FetchDescriptor<Operator>())) ?? []
        let patrons = (try? modelContext.fetch(FetchDescriptor<Patron>())) ?? []
        let authorities = (try? modelContext.fetch(FetchDescriptor<Authority>())) ?? []

        let allNpubs = operators.map(\.npub) + patrons.map(\.npub) + authorities.map(\.npub)

        for npub in allNpubs {
            guard let nsec = KeychainService.loadNsec(forNpub: npub),
                  let privKeyHex = try? NostrKeyService.privateKeyHexFromNsec(nsec),
                  let pubKeyHex = try? NostrKeyService.publicKeyHexFromNpub(npub) else {
                continue
            }

            let since = lastSeenTimestamps[npub]
            let conversations = await dmService.fetchConversations(
                privateKeyHex: privKeyHex,
                publicKeyHex: pubKeyHex,
                since: since
            )

            let lastSeen = lastSeenTimestamps[npub] ?? 0
            var newCount = 0
            var latestTimestamp = lastSeen

            for (_, dms) in conversations {
                for dm in dms where !dm.isFromMe {
                    let ts = Int(dm.createdAt.timeIntervalSince1970)
                    if ts > lastSeen {
                        newCount += 1
                    }
                    latestTimestamp = max(latestTimestamp, ts)
                }
            }

            if newCount > 0 {
                unreadCounts[npub] = (unreadCounts[npub] ?? 0) + newCount
                logger.info("Found \(newCount) new DM(s) for \(npub.prefix(12))")
            }

            if latestTimestamp > lastSeen {
                lastSeenTimestamps[npub] = latestTimestamp
                saveLastSeen()
            }
        }
    }

    // MARK: - Persistence

    private static let storageKey = "dm.lastSeenTimestamps"

    private func saveLastSeen() {
        UserDefaults.standard.set(lastSeenTimestamps, forKey: Self.storageKey)
    }

    private func loadLastSeen() {
        if let saved = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: Int] {
            lastSeenTimestamps = saved
        }
    }
}
