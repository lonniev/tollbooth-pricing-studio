import Foundation

/// Fetches the DPYC federation's supported Nostr relay set from the community
/// registry (`dpyc-community/relays.json`) — the single source of truth. There
/// is no hardcoded relay list in the app; the cached set lives in
/// ``RelaySettings`` with a 3-day TTL.
enum RelayRegistryService {

    private static let relaysURL = URL(
        string: "https://raw.githubusercontent.com/lonniev/dpyc-community/main/relays.json"
    )!

    struct RelaysPayload: Codable {
        let relays: [RelayEntry]
    }

    struct RelayEntry: Codable {
        let url: String
        let primary: Bool?
    }

    /// Fetch the supported relay URLs, ordered primary-first. Throws on
    /// network/parse failure so the caller can keep serving its cached set.
    static func fetchRelays() async throws -> [String] {
        let urlString = relaysURL.absoluteString
        await MainActor.run {
            TrafficLogger.shared.logHTTP(label: "Relays Fetch", method: "GET", url: urlString)
        }

        let (data, response) = try await URLSession.shared.data(from: relaysURL)
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? 0
        let responseHeaders = (http?.allHeaderFields as? [String: String]) ?? [:]
        let bodyPreview = String(data: data.prefix(2000), encoding: .utf8) ?? "<\(data.count) bytes>"

        guard statusCode == 200 else {
            await MainActor.run {
                TrafficLogger.shared.logHTTP(
                    label: "Relays Fetch Failed",
                    method: "GET",
                    url: urlString,
                    statusCode: statusCode,
                    responseHeaders: responseHeaders,
                    responseBody: bodyPreview,
                    error: "HTTP \(statusCode)"
                )
            }
            throw RelayRegistryError.fetchFailed
        }

        let payload = try JSONDecoder().decode(RelaysPayload.self, from: data)

        // Primary first, then array order; keep only wss:// and de-duplicate.
        let primary = payload.relays.filter { $0.primary == true }.map { $0.url }
        let rest = payload.relays.filter { $0.primary != true }.map { $0.url }
        var ordered: [String] = []
        for u in primary + rest where u.hasPrefix("wss://") && !ordered.contains(u) {
            ordered.append(u)
        }

        await MainActor.run {
            TrafficLogger.shared.logHTTP(
                label: "Relays → \(ordered.count) relays",
                method: "GET",
                url: urlString,
                statusCode: 200,
                responseHeaders: responseHeaders,
                responseBody: bodyPreview
            )
        }

        guard !ordered.isEmpty else { throw RelayRegistryError.empty }
        return ordered
    }
}

enum RelayRegistryError: LocalizedError {
    case fetchFailed
    case empty

    var errorDescription: String? {
        switch self {
        case .fetchFailed:
            return "Failed to fetch the DPYC relay registry"
        case .empty:
            return "The DPYC relay registry contained no relays"
        }
    }
}
