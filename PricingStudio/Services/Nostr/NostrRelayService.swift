import Foundation
import OSLog

private let logger = Logger(subsystem: "com.tollbooth.dpyc.PricingStudio", category: "NostrRelay")

/// Manages WebSocket connections to Nostr relays for fetching and publishing events.
final class NostrRelayService: Sendable {

    static let defaultRelays: [URL] = [
        URL(string: "wss://relay.primal.net")!,
        URL(string: "wss://relay.damus.io")!,
        URL(string: "wss://nos.lol")!,
    ]

    let relays: [URL]
    private let session: URLSession

    init(relays: [URL] = defaultRelays) {
        self.relays = relays
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    // MARK: - Fetch DMs

    /// Fetch DM events from all relays for the given pubkey.
    func fetchDMs(pubkeyHex: String, since: Int? = nil) async -> [NostrEvent] {
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

        // Pre-build the REQ JSON string so we can pass a Sendable String into task group
        let subId = UUID().uuidString.prefix(16).lowercased()
        var reqArray: [Any] = ["REQ", String(subId)]
        reqArray.append(contentsOf: filters)
        guard let reqData = try? JSONSerialization.data(withJSONObject: reqArray),
              let reqString = String(data: reqData, encoding: .utf8) else {
            return []
        }

        let relayURLs = relays
        let urlSession = session

        return await withTaskGroup(of: [NostrEvent].self) { group in
            for relay in relayURLs {
                group.addTask {
                    await Self.fetchFromRelay(relay, reqString: reqString, subId: String(subId), session: urlSession)
                }
            }
            var allEvents: [String: NostrEvent] = [:]
            for await events in group {
                for event in events {
                    allEvents[event.id] = event
                }
            }
            return Array(allEvents.values)
        }
    }

    // MARK: - Publish

    /// Publish an event to all relays. Returns per-relay results.
    func publish(_ event: NostrEvent) async -> [(URL, Bool, String)] {
        guard let message = try? event.toRelayMessage() else {
            return relays.map { ($0, false, "serialization failed") }
        }

        let relayURLs = relays
        let urlSession = session

        return await withTaskGroup(of: (URL, Bool, String).self) { group in
            for relay in relayURLs {
                group.addTask {
                    await Self.publishToRelay(relay, message: message, session: urlSession)
                }
            }
            var results: [(URL, Bool, String)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    // MARK: - Static Relay Communication (Sendable-safe)

    /// Fetch events from a single relay using a one-shot WebSocket connection.
    private static func fetchFromRelay(
        _ relay: URL, reqString: String, subId: String, session: URLSession
    ) async -> [NostrEvent] {
        do {
            let ws = session.webSocketTask(with: relay)
            ws.resume()
            defer { ws.cancel(with: .normalClosure, reason: nil) }

            try await ws.send(.string(reqString))

            var events: [NostrEvent] = []
            let deadline = Date().addingTimeInterval(15)

            while Date() < deadline {
                let message = try await withTimeout(seconds: 15) {
                    try await ws.receive()
                }

                switch message {
                case .string(let text):
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
                    } else if type == "CLOSED" || type == "NOTICE" {
                        logger.debug("Relay \(relay.absoluteString): \(text)")
                        break
                    }
                case .data:
                    continue
                @unknown default:
                    continue
                }
            }

            let closeData = try JSONSerialization.data(withJSONObject: ["CLOSE", subId])
            if let closeString = String(data: closeData, encoding: .utf8) {
                try? await ws.send(.string(closeString))
            }

            logger.info("Fetched \(events.count) events from \(relay.absoluteString)")
            return events
        } catch {
            logger.debug("Relay fetch \(relay.absoluteString) failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Publish a message to a single relay.
    private static func publishToRelay(
        _ relay: URL, message: String, session: URLSession
    ) async -> (URL, Bool, String) {
        do {
            let ws = session.webSocketTask(with: relay)
            ws.resume()
            defer { ws.cancel(with: .normalClosure, reason: nil) }

            try await ws.send(.string(message))

            let response = try await withTimeout(seconds: 10) {
                try await ws.receive()
            }

            switch response {
            case .string(let text):
                guard let data = text.data(using: .utf8),
                      let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
                    return (relay, true, text)
                }
                if let type = arr.first as? String, type == "OK",
                   arr.count >= 3, let ok = arr[2] as? Bool {
                    let detail = arr.count > 3 ? (arr[3] as? String ?? "") : ""
                    return (relay, ok, detail)
                }
                return (relay, true, text)
            case .data:
                return (relay, true, "")
            @unknown default:
                return (relay, true, "")
            }
        } catch {
            logger.debug("Relay publish \(relay.absoluteString) failed: \(error.localizedDescription)")
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

    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }
}
