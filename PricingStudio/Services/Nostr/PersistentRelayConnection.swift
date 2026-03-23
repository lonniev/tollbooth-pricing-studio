import Foundation
import Starscream

/// Long-lived WebSocket connection to a Nostr relay that keeps REQ subscriptions
/// open after EOSE and streams EVENT messages via AsyncStream.
///
/// Reconnects with exponential backoff on failure and resubscribes automatically.
final class PersistentRelayConnection: @unchecked Sendable {

    enum ConnectionState: Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting
    }

    let url: URL
    private(set) var state: ConnectionState = .disconnected

    /// Stream of decoded Nostr events from all active subscriptions.
    let events: AsyncStream<NostrEvent>
    private let eventContinuation: AsyncStream<NostrEvent>.Continuation

    private var socket: WebSocket?
    private let delegate = PersistentRelayDelegate()

    /// Active subscriptions: subId → filters, for re-subscribe on reconnect.
    private var subscriptions: [String: [[String: Any]]] = [:]

    /// Reconnection backoff state.
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    private let lock = NSLock()

    init(url: URL) {
        self.url = url
        var continuation: AsyncStream<NostrEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    deinit {
        disconnect()
    }

    // MARK: - Connect

    func connect() async throws {
        state = .connecting

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let origin = "https://\(url.host ?? url.absoluteString)"
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("PricingStudio/1.0", forHTTPHeaderField: "User-Agent")

        let ws = WebSocket(request: request)
        ws.delegate = delegate
        self.socket = ws

        try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Void, Error>) in
            let oneShot = OneShotFlag()

            delegate.onConnect = { [weak self] in
                if oneShot.claim() {
                    self?.state = .connected
                    self?.reconnectAttempt = 0
                    self?.startPinging()
                    self?.startListening()
                    continuation.resume()
                }
            }
            delegate.onError = { [weak self] error in
                if oneShot.claim() {
                    self?.state = .disconnected
                    continuation.resume(throwing: error ?? PersistentRelayError.connectionFailed)
                }
            }

            ws.connect()

            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in
                if oneShot.claim() {
                    ws.disconnect()
                    self?.state = .disconnected
                    continuation.resume(throwing: PersistentRelayError.timeout)
                }
            }
        }
    }

    // MARK: - Subscriptions

    func subscribe(subId: String, filters: [[String: Any]]) {
        lock.lock()
        subscriptions[subId] = filters
        lock.unlock()
        sendSubscription(subId: subId, filters: filters)
    }

    func unsubscribe(subId: String) {
        lock.lock()
        subscriptions.removeValue(forKey: subId)
        lock.unlock()

        if let data = try? JSONSerialization.data(withJSONObject: ["CLOSE", subId]),
           let msg = String(data: data, encoding: .utf8) {
            socket?.write(string: msg)
        }
    }

    // MARK: - Disconnect

    func disconnect() {
        state = .disconnected
        pingTask?.cancel()
        pingTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        socket?.disconnect()
        socket = nil
        eventContinuation.finish()
    }

    // MARK: - Private

    private func sendSubscription(subId: String, filters: [[String: Any]]) {
        var reqArray: [Any] = ["REQ", subId]
        reqArray.append(contentsOf: filters)
        guard let data = try? JSONSerialization.data(withJSONObject: reqArray),
              let msg = String(data: data, encoding: .utf8) else { return }
        socket?.write(string: msg)
    }

    private func resubscribeAll() {
        lock.lock()
        let subs = subscriptions
        lock.unlock()
        for (subId, filters) in subs {
            sendSubscription(subId: subId, filters: filters)
        }
    }

    private func startListening() {
        delegate.onText = { [weak self] text in
            self?.handleMessage(text)
        }
        delegate.onDisconnect = { [weak self] _ in
            self?.scheduleReconnect()
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = arr.first as? String else { return }

        if type == "EVENT", arr.count >= 3,
           let eventObj = arr[2] as? [String: Any],
           let event = Self.parseEvent(eventObj) {
            eventContinuation.yield(event)
        }
        // EOSE — subscription is now live, nothing to do (stay open)
        // AUTH, CLOSED, NOTICE — log but don't disconnect
    }

    // MARK: - Reconnection

    private func scheduleReconnect() {
        guard state != .disconnected else { return }
        state = .reconnecting

        let attempt = reconnectAttempt
        reconnectAttempt += 1
        let delay = min(Double(1 << min(attempt, 6)), 60.0)  // 1s, 2s, 4s, ... 60s max

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            do {
                try await self.connect()
                self.resubscribeAll()
            } catch {
                self.scheduleReconnect()
            }
        }
    }

    // MARK: - Keepalive

    private func startPinging() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.state == .connected else { break }
                self.socket?.write(ping: Data())
            }
        }
    }

    // MARK: - Helpers

    private static func parseEvent(_ dict: [String: Any]) -> NostrEvent? {
        guard let id = dict["id"] as? String,
              let pubkey = dict["pubkey"] as? String,
              let createdAt = dict["created_at"] as? Int,
              let kind = dict["kind"] as? Int,
              let tags = dict["tags"] as? [[String]],
              let content = dict["content"] as? String,
              let sig = dict["sig"] as? String else {
            return nil
        }
        return NostrEvent(
            id: id, pubkey: pubkey, created_at: createdAt,
            kind: kind, tags: tags, content: content, sig: sig
        )
    }
}

// MARK: - Delegate

private final class PersistentRelayDelegate: @unchecked Sendable, WebSocketDelegate {
    var onConnect: (() -> Void)?
    var onText: ((String) -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var onError: ((Error?) -> Void)?

    func didReceive(event: WebSocketEvent, client: any WebSocketClient) {
        switch event {
        case .connected:
            onConnect?()
        case .text(let text):
            onText?(text)
        case .disconnected(_, _):
            onDisconnect?(nil)
        case .error(let error):
            onError?(error)
            onDisconnect?(error)
        case .cancelled:
            onDisconnect?(nil)
        case .viabilityChanged, .reconnectSuggested, .peerClosed:
            break
        case .binary, .ping, .pong:
            break
        }
    }
}

// MARK: - Thread-safe flag

private final class OneShotFlag: @unchecked Sendable {
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

private enum PersistentRelayError: LocalizedError {
    case connectionFailed
    case timeout

    var errorDescription: String? {
        switch self {
        case .connectionFailed: "Persistent WebSocket connection failed"
        case .timeout: "Persistent WebSocket connection timed out"
        }
    }
}
