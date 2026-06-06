import Foundation
import OSLog

private let logger = Logger(subsystem: "com.tollbooth.dpyc.PricingStudio", category: "Chat")

/// View model for the DM chat interface.
///
/// Manages conversations, identity switching, and relay communication.
/// Uses a 2-minute in-memory cache to avoid redundant relay fetches.
@MainActor
@Observable
final class ChatViewModel {

    // MARK: - State

    enum State: Sendable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    private(set) var state: State = .idle
    var conversations: [DMConversation] = []
    var selectedConversationId: String?

    /// IDs of optimistically-added messages not yet confirmed by relay.
    private(set) var pendingMessageIds: Set<String> = []

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    /// Font customization persisted in UserDefaults.
    var messageFontName: String {
        didSet { UserDefaults.standard.set(messageFontName, forKey: "chat.fontName") }
    }
    var messageFontSize: CGFloat {
        didSet { UserDefaults.standard.set(messageFontSize, forKey: "chat.fontSize") }
    }

    // MARK: - Identity

    private(set) var currentIdentity: ChatIdentity?

    // MARK: - Private

    private let dmService = NostrDMService()
    private var conversationCache: [String: CachedConversations] = [:]  // keyed by npub
    private static let cacheDuration: TimeInterval = 120  // 2 minutes

    // MARK: - Init

    init() {
        self.messageFontName = UserDefaults.standard.string(forKey: "chat.fontName") ?? "SF Mono"
        let savedSize = UserDefaults.standard.double(forKey: "chat.fontSize")
        self.messageFontSize = savedSize > 0 ? savedSize : 14

        // Register for live DM delivery from subscriptions
        DMPollingService.shared.onLiveDM = { [weak self] npub, dm in
            self?.injectLiveDM(npub: npub, dm: dm)
        }
    }

    /// Inject a live DM from subscriptions directly into the active conversation.
    private func injectLiveDM(npub: String, dm: DecryptedDM) {
        let counterpartyHex = dm.isFromMe ? dm.recipientPubkeyHex : dm.senderPubkeyHex

        // Skip self-conversations (sender == recipient)
        if dm.senderPubkeyHex == dm.recipientPubkeyHex { return }
        let myPubHex = try? NostrKeyService.publicKeyHexFromNpub(npub)
        if counterpartyHex == myPubHex { return }

        let isActiveIdentity = currentIdentity?.npub == npub

        // Always update the cache for this npub — even if not currently viewing it.
        // This way switchIdentity finds cached conversations and skips the relay fetch.
        var cached = conversationCache[npub]?.conversations ?? []

        if let idx = cached.firstIndex(where: { $0.counterpartyPubkeyHex == counterpartyHex }) {
            // Check for exact duplicate by event ID
            guard !cached[idx].messages.contains(where: { $0.rawEventId == dm.rawEventId }) else { return }
            // Check for cross-protocol duplicate (NIP-04 + NIP-17 = same message, different event IDs)
            // Keep the one with the more recent timestamp (NIP-04 has real time, NIP-17 is fuzzed back)
            if let dupIdx = cached[idx].messages.firstIndex(where: {
                $0.senderPubkeyHex == dm.senderPubkeyHex
                && $0.content == dm.content
                && abs($0.createdAt.timeIntervalSince(dm.createdAt)) < 48 * 60 * 60
            }) {
                // Replace if incoming has a more recent (accurate) timestamp
                if dm.createdAt > cached[idx].messages[dupIdx].createdAt {
                    cached[idx].messages[dupIdx] = dm
                }
                return
            }
            // Check for optimistic duplicate (same content + approximate time = relay echo of our sent message)
            if dm.isFromMe,
               let optimisticIdx = cached[idx].messages.firstIndex(where: {
                   $0.isFromMe && $0.content == dm.content
                   && abs($0.createdAt.timeIntervalSince(dm.createdAt)) < 120
                   && pendingMessageIds.contains($0.rawEventId)
               }) {
                // Replace optimistic with real event
                pendingMessageIds.remove(cached[idx].messages[optimisticIdx].rawEventId)
                cached[idx].messages[optimisticIdx] = dm
            } else {
                cached[idx].messages.append(dm)
            }
        } else {
            cached.insert(
                DMConversation(counterpartyPubkeyHex: counterpartyHex, messages: [dm]),
                at: 0
            )
        }

        conversationCache[npub] = CachedConversations(
            conversations: cached,
            fetchedAt: Date()
        )

        // If this is the active identity, update in-place instead of replacing
        // the entire array — preserves scroll position and reduces SwiftUI diff work
        if isActiveIdentity {
            if let idx = conversations.firstIndex(where: { $0.counterpartyPubkeyHex == counterpartyHex }) {
                if conversations[idx].messages.contains(where: { $0.rawEventId == dm.rawEventId }) {
                    // Already present — skip
                } else if let dupIdx = conversations[idx].messages.firstIndex(where: {
                    $0.senderPubkeyHex == dm.senderPubkeyHex
                    && $0.content == dm.content
                    && abs($0.createdAt.timeIntervalSince(dm.createdAt)) < 48 * 60 * 60
                }) {
                    // Cross-protocol duplicate — keep the one with the more recent timestamp
                    if dm.createdAt > conversations[idx].messages[dupIdx].createdAt {
                        conversations[idx].messages[dupIdx] = dm
                    }
                } else if dm.isFromMe,
                          let optIdx = conversations[idx].messages.firstIndex(where: {
                              $0.isFromMe && $0.content == dm.content
                              && abs($0.createdAt.timeIntervalSince(dm.createdAt)) < 120
                              && pendingMessageIds.contains($0.rawEventId)
                          }) {
                    // Replace optimistic with real event
                    pendingMessageIds.remove(conversations[idx].messages[optIdx].rawEventId)
                    conversations[idx].messages[optIdx] = dm
                } else {
                    conversations[idx].messages.append(dm)
                }
            } else {
                conversations.insert(
                    DMConversation(counterpartyPubkeyHex: counterpartyHex, messages: [dm]),
                    at: 0
                )
            }
            state = .loaded
        }
    }

    // MARK: - Merge Conversations

    /// Merge relay-fetched conversations with existing ones.
    /// Preserves existing messages (subscription-injected, optimistic sends)
    /// and adds any new ones from the relay fetch.
    private func mergeConversations(_ incoming: [DMConversation]) {
        var merged = conversations
        for convo in incoming {
            if let idx = merged.firstIndex(where: { $0.counterpartyPubkeyHex == convo.counterpartyPubkeyHex }) {
                // Merge messages: add any from incoming that aren't already present
                let existingIds = Set(merged[idx].messages.map(\.rawEventId))
                let newMessages = convo.messages.filter { !existingIds.contains($0.rawEventId) }
                merged[idx].messages.append(contentsOf: newMessages)
                merged[idx].messages.sort { $0.createdAt < $1.createdAt }
            } else {
                merged.append(convo)
            }
        }
        // Sort conversations by latest message
        merged.sort { ($0.latestMessage?.createdAt ?? .distantPast) > ($1.latestMessage?.createdAt ?? .distantPast) }
        conversations = merged
    }

    // MARK: - Identity Switching

    /// Switch the chat identity. Cancels pending work and resets state.
    /// Auto-loads conversations if the identity has an nsec and cache is fresh.
    func switchIdentity(to identity: ChatIdentity?) {
        guard identity?.npub != currentIdentity?.npub else { return }
        currentIdentity = identity
        conversations = []
        selectedConversationId = nil

        guard let identity, identity.hasNsec else {
            state = .idle
            return
        }

        // Show cached conversations immediately (if any), then always
        // do a background relay fetch for full history.
        if let cached = conversationCache[identity.npub], !cached.conversations.isEmpty {
            conversations = cached.conversations
            state = .loaded
        }

        // Always fetch from relays — subscription cache is partial (only recent DMs).
        // Silent when we already have something to show; blocking otherwise.
        let hasCachedContent = !conversations.isEmpty
        Task { await loadConversations(silent: hasCachedContent) }
    }

    // MARK: - Load Conversations

    /// Fetch and decrypt conversations from relays.
    /// When `silent` is true, doesn't show the loading spinner (for background refreshes).
    func loadConversations(silent: Bool = false) async {
        guard let identity = currentIdentity,
              let privHex = identity.privateKeyHex else {
            state = .idle
            return
        }

        // Check cache first
        if let cached = conversationCache[identity.npub],
           Date().timeIntervalSince(cached.fetchedAt) < Self.cacheDuration {
            conversations = cached.conversations
            state = .loaded
            return
        }

        if !silent { state = .loading }
        let pubHex = identity.publicKeyHex
        let timeout: TimeInterval = 45  // relays can be slow — give them time

        await MainActor.run {
            TrafficLogger.shared.log(.outbound, label: "DM Fetch", detail: "Fetching conversations for \(identity.npub.prefix(12))… (timeout=\(Int(timeout))s)", npub: identity.npub)
        }

        do {
            let dmsByCounterparty = try await withOverallTimeout(seconds: timeout) {
                await self.dmService.fetchConversations(
                    privateKeyHex: privHex,
                    publicKeyHex: pubHex
                )
            }

            let convos = dmsByCounterparty
                .filter { counterparty, _ in counterparty != pubHex }  // exclude self-conversations
                .map { (counterparty, messages) in
                    DMConversation(counterpartyPubkeyHex: counterparty, messages: messages)
                }.sorted { ($0.latestMessage?.createdAt ?? .distantPast) > ($1.latestMessage?.createdAt ?? .distantPast) }

            let msgCount = convos.reduce(0) { $0 + $1.messages.count }
            await MainActor.run {
                TrafficLogger.shared.log(.inbound, label: "DM Fetch", detail: "\(convos.count) conversations, \(msgCount) messages", npub: identity.npub)
            }

            // Merge relay results with existing conversations instead of replacing.
            // This preserves subscription-injected messages and the user's scroll position.
            mergeConversations(convos)
            pendingMessageIds.removeAll()
            conversationCache[identity.npub] = CachedConversations(
                conversations: conversations,
                fetchedAt: Date()
            )
            state = .loaded
            fetchError = nil

            logger.info("Loaded \(convos.count) conversations for \(identity.npub.prefix(12))")
        } catch is ChatTimeoutError {
            let msg = "Relay fetch timed out. Subscription events will populate conversations."
            await MainActor.run {
                TrafficLogger.shared.log(.error, label: "DM Fetch", detail: msg, npub: identity.npub)
            }
            if !silent && conversations.isEmpty {
                state = .error(msg)
            } else {
                state = .loaded
                fetchError = silent ? nil : msg
            }
            logger.error("DM fetch timed out for \(identity.npub.prefix(12))")
        } catch {
            let msg = error.localizedDescription
            await MainActor.run {
                TrafficLogger.shared.log(.error, label: "DM Fetch", detail: msg, npub: identity.npub)
            }
            if !silent && conversations.isEmpty {
                state = .error(msg)
            } else {
                state = .loaded
                fetchError = silent ? nil : msg
            }
            logger.error("DM fetch failed: \(msg)")
        }
    }

    /// Force refresh — bypasses cache. Silent when subscriptions are active.
    func refreshConversations() async {
        if let npub = currentIdentity?.npub {
            conversationCache.removeValue(forKey: npub)
        }
        await loadConversations(silent: DMPollingService.shared.subscriptionsActive)
    }

    // MARK: - Send Message

    /// Last send error, surfaced as an alert instead of replacing the chat view.
    var sendError: String?

    /// Last fetch error, shown as a non-destructive banner when conversations are already loaded.
    var fetchError: String?

    /// Send a DM to the given counterparty via dual protocol.
    func sendMessage(to counterpartyPubkeyHex: String, content: String) async {
        guard let identity = currentIdentity,
              let privHex = identity.privateKeyHex else {
            sendError = "No private key available for this identity. Add an nsec in the entity editor."
            return
        }

        // Show optimistic message immediately — before the relay round-trip
        let optimisticId = UUID().uuidString
        let dm = DecryptedDM(
            rawEventId: optimisticId,
            senderPubkeyHex: identity.publicKeyHex,
            recipientPubkeyHex: counterpartyPubkeyHex,
            content: content,
            createdAt: Date(),
            encryption: .nip04,
            isFromMe: true
        )
        pendingMessageIds.insert(optimisticId)

        if let idx = conversations.firstIndex(where: { $0.counterpartyPubkeyHex == counterpartyPubkeyHex }) {
            conversations[idx].messages.append(dm)
        } else {
            conversations.insert(
                DMConversation(counterpartyPubkeyHex: counterpartyPubkeyHex, messages: [dm]),
                at: 0
            )
        }

        // Courier relay pinning: if the counterparty's latest courier DM
        // names a rendezvous relay, the reply MUST be published there —
        // the courier's listener drains only that relay.
        let pinnedRelay = conversations
            .first(where: { $0.counterpartyPubkeyHex == counterpartyPubkeyHex })?
            .messages
            .filter { !$0.isFromMe }
            .reversed()
            .compactMap { CourierPayload.parse($0.content)?.rendezvousRelay?.value }
            .compactMap { URL(string: $0) }
            .first

        // Send to relay in background — message is already visible as pending
        do {
            try await dmService.sendDM(
                privateKeyHex: privHex,
                publicKeyHex: identity.publicKeyHex,
                recipientPubkeyHex: counterpartyPubkeyHex,
                message: content,
                pinnedRelay: pinnedRelay
            )
            // Relay accepted — clear pending state and update cache immediately
            pendingMessageIds.remove(optimisticId)
            if let npub = currentIdentity?.npub {
                conversationCache[npub] = CachedConversations(
                    conversations: conversations,
                    fetchedAt: Date()
                )
            }
            // Signal poll watchers so UI refreshes without waiting for next cycle
            DMPollingService.shared.notifyUpdate()
        } catch {
            // Send failed — remove optimistic message and show error
            pendingMessageIds.remove(optimisticId)
            if let idx = conversations.firstIndex(where: { $0.counterpartyPubkeyHex == counterpartyPubkeyHex }) {
                conversations[idx].messages.removeAll { $0.rawEventId == optimisticId }
            }
            sendError = error.localizedDescription
            logger.error("Send failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Delete Messages (NIP-09)

    /// Request deletion of specific events from relays.
    func requestDeletion(eventIds: [String]) async {
        guard let identity = currentIdentity,
              let privHex = identity.privateKeyHex else { return }

        await dmService.requestDeletion(
            privateKeyHex: privHex,
            publicKeyHex: identity.publicKeyHex,
            eventIds: eventIds
        )

        // Remove from local state
        for i in conversations.indices {
            conversations[i].messages.removeAll { eventIds.contains($0.rawEventId) }
        }
        conversations.removeAll { $0.messages.isEmpty }
    }

    /// Delete all messages in the selected conversation from relays.
    func clearAllMessages() async {
        guard let convId = selectedConversationId,
              let convo = conversations.first(where: { $0.id == convId }) else { return }

        let eventIds = convo.messages.map(\.rawEventId)
        await requestDeletion(eventIds: eventIds)
    }

    // MARK: - Selected Conversation

    var selectedConversation: DMConversation? {
        guard let id = selectedConversationId else { return nil }
        return conversations.first { $0.id == id }
    }
}

// MARK: - Cache

private struct CachedConversations {
    let conversations: [DMConversation]
    let fetchedAt: Date
}

// MARK: - Timeout

private struct ChatTimeoutError: Error {}

/// Race an async operation against a deadline. Throws ChatTimeoutError on timeout.
private func withOverallTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @Sendable @escaping () async -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw ChatTimeoutError()
        }
        guard let result = try await group.next() else {
            throw ChatTimeoutError()
        }
        group.cancelAll()
        return result
    }
}
