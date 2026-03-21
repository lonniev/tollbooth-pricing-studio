import Foundation

struct TrafficLogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let direction: Direction
    let label: String
    let detail: String

    /// The npub this entry is associated with, if any.
    /// Entries with nil are considered general app-level traffic.
    let associatedNpub: String?

    // Structured HTTP fields (optional — populated when available)
    let method: String?
    let url: String?
    let requestHeaders: [String: String]?
    let requestBody: String?
    let statusCode: Int?
    let responseHeaders: [String: String]?
    let responseBody: String?

    enum Direction: String, Sendable {
        case outbound = "OUT"
        case inbound = "IN"
        case error = "ERR"
    }

    /// Whether this entry is a Nostr messaging or relay event.
    var isNostrEvent: Bool {
        label.hasPrefix("DM ") || label.hasPrefix("Relay ")
    }

    init(
        timestamp: Date,
        direction: Direction,
        label: String,
        detail: String,
        associatedNpub: String? = nil,
        method: String? = nil,
        url: String? = nil,
        requestHeaders: [String: String]? = nil,
        requestBody: String? = nil,
        statusCode: Int? = nil,
        responseHeaders: [String: String]? = nil,
        responseBody: String? = nil
    ) {
        self.timestamp = timestamp
        self.direction = direction
        self.label = label
        self.detail = detail
        self.associatedNpub = associatedNpub
        self.method = method
        self.url = url
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.statusCode = statusCode
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
    }
}

@Observable @MainActor
final class TrafficLogger {
    static let shared = TrafficLogger()

    /// Maximum entries retained in memory. Oldest entries are evicted first.
    static let maxEntries = 2000

    private(set) var entries: [TrafficLogEntry] = []

    /// Simple log (MCP protocol-level events).
    func log(_ direction: TrafficLogEntry.Direction, label: String, detail: String, npub: String? = nil) {
        append(TrafficLogEntry(
            timestamp: Date(),
            direction: direction,
            label: label,
            detail: redactSecrets(detail),
            associatedNpub: npub
        ))
    }

    /// Structured HTTP log — captures full request/response detail.
    func logHTTP(
        label: String,
        method: String,
        url: String,
        requestHeaders: [String: String]? = nil,
        requestBody: String? = nil,
        statusCode: Int? = nil,
        responseHeaders: [String: String]? = nil,
        responseBody: String? = nil,
        error: String? = nil,
        npub: String? = nil
    ) {
        let direction: TrafficLogEntry.Direction = error != nil ? .error : (statusCode != nil ? .inbound : .outbound)
        let detail = error ?? (statusCode.map { "HTTP \($0)" } ?? "\(method) \(url)")
        append(TrafficLogEntry(
            timestamp: Date(),
            direction: direction,
            label: redactSecrets(label),
            detail: redactSecrets(detail),
            associatedNpub: npub,
            method: method,
            url: redactSecrets(url),
            requestHeaders: requestHeaders?.mapValues { redactSecrets($0) },
            requestBody: requestBody.map { redactSecrets(String($0.prefix(4000))) },
            statusCode: statusCode,
            responseHeaders: responseHeaders?.mapValues { redactSecrets($0) },
            responseBody: responseBody.map { redactSecrets(String($0.prefix(4000))) }
        ))
    }

    func clear() {
        entries.removeAll()
    }

    // MARK: - Rolling Buffer

    private func append(_ entry: TrafficLogEntry) {
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }

    // MARK: - Redaction

    /// Replace any nsec1... bech32 strings with a redacted placeholder.
    private func redactSecrets(_ text: String) -> String {
        let pattern = #"nsec1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{10,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "nsec1\u{2022}\u{2022}\u{2022}redacted"
        )
    }
}
