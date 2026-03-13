import Foundation

enum RegistryService {

    private static let registryURL = URL(string: "https://raw.githubusercontent.com/lonniev/dpyc-community/main/members/read-only-lookup-cache.json")!

    struct RegistryWrapper: Codable {
        let members: [RegistryEntry]
    }

    struct RegistryEntry: Codable {
        let npub: String
        let role: String
        let status: String?
        let display_name: String?
        let upstream_authority_npub: String?
        let services: [ServiceEntry]?
    }

    struct ServiceEntry: Codable {
        let name: String
        let url: String
        let description: String?
    }

    /// Resolve Oracle URL by walking the authority chain from an operator's upstream authority
    /// up to the Prime Authority, which hosts the dpyc-oracle service.
    static func resolveOracleURL(forOperator operatorNpub: String) async throws -> URL {
        let entries = try await fetchRegistry()

        let entryByNpub = Dictionary(uniqueKeysWithValues: entries.map { ($0.npub, $0) })

        // Find the operator entry to start the chain walk
        guard let operatorEntry = entryByNpub[operatorNpub] else {
            throw RegistryError.operatorNotFound
        }

        // Walk upstream from the operator's authority toward the Prime Authority
        var currentNpub = operatorEntry.upstream_authority_npub ?? operatorNpub
        var visited: Set<String> = [operatorNpub]
        let maxHops = 10

        for _ in 0..<maxHops {
            guard !visited.contains(currentNpub) else {
                // Cycle detected — check current entry for oracle
                break
            }
            visited.insert(currentNpub)

            guard let entry = entryByNpub[currentNpub] else { break }

            // Check if this entry hosts the dpyc-oracle
            if let oracleService = entry.services?.first(where: { $0.name == "dpyc-oracle" }),
               let url = URL(string: oracleService.url) {
                return url
            }

            // Continue walking upstream
            guard let upstream = entry.upstream_authority_npub else { break }
            currentNpub = upstream
        }

        // Fallback: scan all entries for any oracle service
        return try resolveOracleURLFallback(entries: entries)
    }

    /// Simple fallback: find any entry hosting dpyc-oracle
    private static func resolveOracleURLFallback(entries: [RegistryEntry]) throws -> URL {
        guard let oracleEntry = entries.first(where: { entry in
            entry.services?.contains(where: { $0.name == "dpyc-oracle" }) ?? false
        }),
        let oracleService = oracleEntry.services?.first(where: { $0.name == "dpyc-oracle" }),
        let url = URL(string: oracleService.url) else {
            throw RegistryError.oracleNotFound
        }
        return url
    }

    /// Legacy entry point for callers that don't have an operator npub
    static func resolveOracleURL() async throws -> URL {
        let entries = try await fetchRegistry()
        return try resolveOracleURLFallback(entries: entries)
    }

    private static func fetchRegistry() async throws -> [RegistryEntry] {
        let urlString = registryURL.absoluteString
        await MainActor.run {
            TrafficLogger.shared.logHTTP(label: "Registry Fetch", method: "GET", url: urlString)
        }
        let (data, response) = try await URLSession.shared.data(from: registryURL)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 0
        let responseHeaders = (httpResponse?.allHeaderFields as? [String: String]) ?? [:]
        let bodyPreview = String(data: data.prefix(2000), encoding: .utf8) ?? "<\(data.count) bytes>"

        guard statusCode == 200 else {
            await MainActor.run {
                TrafficLogger.shared.logHTTP(
                    label: "Registry Fetch Failed",
                    method: "GET",
                    url: urlString,
                    statusCode: statusCode,
                    responseHeaders: responseHeaders,
                    responseBody: bodyPreview,
                    error: "HTTP \(statusCode)"
                )
            }
            throw RegistryError.fetchFailed
        }
        let entries = try JSONDecoder().decode(RegistryWrapper.self, from: data).members
        await MainActor.run {
            TrafficLogger.shared.logHTTP(
                label: "Registry → \(entries.count) entries",
                method: "GET",
                url: urlString,
                statusCode: 200,
                responseHeaders: responseHeaders,
                responseBody: bodyPreview
            )
        }
        return entries
    }
}

enum RegistryError: LocalizedError {
    case fetchFailed
    case oracleNotFound
    case operatorNotFound

    var errorDescription: String? {
        switch self {
        case .fetchFailed:
            return "Failed to fetch the DPYC community registry"
        case .oracleNotFound:
            return "Oracle service not found in the registry"
        case .operatorNotFound:
            return "Operator not found in the registry"
        }
    }
}
