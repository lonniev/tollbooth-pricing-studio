import Foundation
@preconcurrency import Starscream

/// Manages WebSocket connections to Nostr relays for fetching and publishing events.
/// Uses Starscream instead of URLSessionWebSocketTask to avoid iOS compression
/// negotiation failures (permessage-deflate) that cause -1011 on real devices.
final class NostrRelayService: Sendable {

    static var defaultRelays: [URL] {
        let strings = UserDefaults.standard.stringArray(forKey: RelaySettings.storageKey)
            ?? RelaySettings.defaultRelayStrings
        return strings.compactMap { URL(string: $0) }
    }

    let relays: [URL]

    init(relays: [URL] = defaultRelays) {
        self.relays = relays
    }

    // MARK: - Fetch DMs

    /// Fetch DM events from all relays for the given pubkey.
    /// Fetch DM events, trying the primary relay first with fallback rotation.
    /// Returns (events, relay that succeeded) for affinity tracking.
    func fetchDMs(pubkeyHex: String, since: Int? = nil, primaryRelay: URL? = nil) async -> (events: [NostrEvent], relay: URL?) {
        let sinceTimestamp = since ?? Int(Date().timeIntervalSince1970) - (7 * 24 * 60 * 60)

        let filterNIP04Inbound: [String: Any] = [
            "kinds": [4],
            "#p": [pubkeyHex],
            "since": sinceTimestamp,
            "limit": 100,
        ]
        let filterNIP04Outbound: [String: Any] = [
            "kinds": [4],
            "authors": [pubkeyHex],
            "since": sinceTimestamp,
            "limit": 100,
        ]
        let filterGiftWrap: [String: Any] = [
            "kinds": [1059],
            "#p": [pubkeyHex],
            "since": sinceTimestamp - (48 * 60 * 60),
            "limit": 100,
        ]

        let filters = [filterNIP04Inbound, filterNIP04Outbound, filterGiftWrap]

        let subId = UUID().uuidString.prefix(16).lowercased()
        var reqArray: [Any] = ["REQ", String(subId)]
        reqArray.append(contentsOf: filters)
        guard let reqData = try? JSONSerialization.data(withJSONObject: reqArray),
              let reqString = String(data: reqData, encoding: .utf8) else {
            return ([], nil)
        }

        // Build relay order: primary first, then remaining relays
        var orderedRelays = relays
        if let primary = primaryRelay, let idx = orderedRelays.firstIndex(of: primary) {
            orderedRelays.remove(at: idx)
            orderedRelays.insert(primary, at: 0)
        }

        // Try relays sequentially — return on first success
        for relay in orderedRelays {
            let events = await Self.fetchFromRelay(relay, reqString: reqString, subId: String(subId))
            if !events.isEmpty {
                return (events, relay)
            }
        }

        return ([], nil)
    }

    // MARK: - Publish

    /// Publish an event to ALL relays in parallel — maximizes reach.
    func publish(_ event: NostrEvent, primaryRelay: URL? = nil) async -> [(URL, Bool, String)] {
        guard let message = try? event.toRelayMessage() else {
            return relays.map { ($0, false, "serialization failed") }
        }

        return await withTaskGroup(of: (URL, Bool, String).self) { group in
            for relay in relays {
                group.addTask {
                    await Self.publishToRelay(relay, message: message)
                }
            }
            var results: [(URL, Bool, String)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    // MARK: - Starscream Relay Communication

    /// Fetch events from a single relay using a one-shot Starscream WebSocket.
    private static func fetchFromRelay(
        _ relay: URL, reqString: String, subId: String
    ) async -> [NostrEvent] {
        let host = relay.host ?? relay.absoluteString
        await MainActor.run {
            TrafficLogger.shared.log(.outbound, label: "Relay Connect", detail: host)
        }

        do {
            let conn = RelayConnection(url: relay)
            try await conn.connect(timeout: 30)
            conn.send(reqString)

            var events: [NostrEvent] = []
            let deadline = Date().addingTimeInterval(45)

            while Date() < deadline {
                guard let text = try await conn.receive(timeout: 30) else { break }

                guard let data = text.data(using: .utf8),
                      let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                      let type = arr.first as? String else { continue }

                if type == "EVENT", arr.count >= 3,
                   let eventObj = arr[2] as? [String: Any] {
                    if let event = parseEvent(eventObj) {
                        events.append(event)
                    }
                } else if type == "EOSE" {
                    break
                } else if type == "AUTH" {
                    await MainActor.run {
                        TrafficLogger.shared.log(.error, label: "Relay AUTH", detail: "\(host): NIP-42 required — skipping")
                    }
                    break
                } else if type == "CLOSED" || type == "NOTICE" {
                    break
                }
            }

            // Send CLOSE and disconnect
            let closeData = try JSONSerialization.data(withJSONObject: ["CLOSE", subId])
            if let closeString = String(data: closeData, encoding: .utf8) {
                conn.send(closeString)
            }
            conn.disconnect()

            await MainActor.run {
                TrafficLogger.shared.log(.inbound, label: "Relay \(host)", detail: "\(events.count) events")
            }
            return events
        } catch {
            await MainActor.run {
                TrafficLogger.shared.log(.error, label: "Relay Fetch Failed", detail: "\(host): \(Self.describeError(error))")
            }
            return []
        }
    }

    /// Extract actionable info from Starscream errors.
    private static func describeError(_ error: Error) -> String {
        if let upgrade = error as? HTTPUpgradeError {
            switch upgrade {
            case .notAnUpgrade(let statusCode, _):
                return "HTTP \(statusCode) — upgrade rejected"
            case .invalidData:
                return "Invalid upgrade response"
            }
        }
        return error.localizedDescription
    }

    /// Publish a message to a single relay.
    private static func publishToRelay(
        _ relay: URL, message: String
    ) async -> (URL, Bool, String) {
        let host = relay.host ?? relay.absoluteString
        await MainActor.run {
            TrafficLogger.shared.log(.outbound, label: "Relay Publish", detail: host)
        }

        do {
            let conn = RelayConnection(url: relay)
            try await conn.connect(timeout: 30)
            conn.send(message)

            guard let text = try await conn.receive(timeout: 30) else {
                conn.disconnect()
                return (relay, true, "no response")
            }
            conn.disconnect()

            guard let data = text.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
                await MainActor.run {
                    TrafficLogger.shared.log(.inbound, label: "Relay Publish OK", detail: host)
                }
                return (relay, true, text)
            }
            if let type = arr.first as? String, type == "OK",
               arr.count >= 3, let ok = arr[2] as? Bool {
                let detail = arr.count > 3 ? (arr[3] as? String ?? "") : ""
                await MainActor.run {
                    TrafficLogger.shared.log(.inbound, label: "Relay Publish \(ok ? "OK" : "Rejected")", detail: "\(host): \(detail)")
                }
                return (relay, ok, detail)
            }
            await MainActor.run {
                TrafficLogger.shared.log(.inbound, label: "Relay Publish OK", detail: host)
            }
            return (relay, true, text)
        } catch {
            await MainActor.run {
                TrafficLogger.shared.log(.error, label: "Relay Publish Failed", detail: "\(host): \(Self.describeError(error))")
            }
            return (relay, false, error.localizedDescription)
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

// MARK: - Starscream WebSocket Wrapper

/// Wraps a Starscream WebSocket in async/await for one-shot relay connections.
private final class RelayConnection: @unchecked Sendable {
    private let socket: WebSocket
    private let delegate: RelayDelegate

    init(url: URL) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        // Headers required to pass Cloudflare bot protection on relay frontends.
        // Without Origin + User-Agent, CF returns 403 and blocks the WS upgrade.
        let origin = "https://\(url.host ?? url.absoluteString)"
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("PricingStudio/1.0", forHTTPHeaderField: "User-Agent")
        self.delegate = RelayDelegate()
        self.socket = WebSocket(request: request)
        self.socket.delegate = delegate
    }

    /// Connect and wait for the WebSocket to open.
    func connect(timeout: TimeInterval) async throws {
        try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Void, Error>) in
            let state = OneShotState()

            delegate.onConnect = {
                if state.claim() {
                    continuation.resume()
                }
            }
            delegate.onError = { error in
                if state.claim() {
                    continuation.resume(throwing: error ?? RelayError.connectionFailed)
                }
            }

            socket.connect()

            // Timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if state.claim() {
                    self.socket.disconnect()
                    continuation.resume(throwing: RelayError.timeout)
                }
            }
        }
    }

    /// Send a text message.
    func send(_ text: String) {
        socket.write(string: text)
    }

    /// Wait for the next text message, or nil on disconnect/timeout.
    func receive(timeout: TimeInterval) async throws -> String? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
            let state = OneShotState()

            delegate.onText = { [weak delegate] text in
                if state.claim() {
                    delegate?.onText = nil
                    delegate?.onDisconnect = nil
                    delegate?.onError = nil
                    continuation.resume(returning: text)
                }
            }
            delegate.onDisconnect = { [weak delegate] error in
                if state.claim() {
                    delegate?.onText = nil
                    delegate?.onDisconnect = nil
                    delegate?.onError = nil
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
            delegate.onError = { [weak delegate] error in
                if state.claim() {
                    delegate?.onText = nil
                    delegate?.onDisconnect = nil
                    delegate?.onError = nil
                    continuation.resume(throwing: error ?? RelayError.unknown)
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak delegate] in
                if state.claim() {
                    delegate?.onText = nil
                    delegate?.onDisconnect = nil
                    delegate?.onError = nil
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func disconnect() {
        socket.disconnect()
    }
}

/// Delegate that bridges Starscream callbacks to closures.
private final class RelayDelegate: @unchecked Sendable, WebSocketDelegate {
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
        case .cancelled:
            onDisconnect?(nil)
        case .peerClosed:
            // Relay closed cleanly — same treatment as disconnect.
            onDisconnect?(nil)
        case .reconnectSuggested(let suggested):
            if suggested { onDisconnect?(nil) }
        case .viabilityChanged(let viable):
            if !viable { onDisconnect?(nil) }
        case .binary, .ping, .pong:
            break
        }
    }
}

/// Thread-safe one-shot flag for continuation racing.
private final class OneShotState: @unchecked Sendable {
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

private enum RelayError: LocalizedError {
    case connectionFailed
    case timeout
    case unknown

    var errorDescription: String? {
        switch self {
        case .connectionFailed: "WebSocket connection failed"
        case .timeout: "WebSocket connection timed out"
        case .unknown: "Unknown WebSocket error"
        }
    }
}
