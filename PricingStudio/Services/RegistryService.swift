import Foundation

enum RegistryService {

    private static let registryURL = URL(string: "https://raw.githubusercontent.com/lonniev/dpyc-community/main/members/read-only-lookup-cache.json")!

    struct RegistryEntry: Codable {
        let npub: String
        let role: String
        let status: String?
        let display_name: String?
        let services: [ServiceEntry]?
    }

    struct ServiceEntry: Codable {
        let name: String
        let type: String
        let url: String
    }

    static func resolveOracleURL() async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: registryURL)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw RegistryError.fetchFailed
        }
        let entries = try JSONDecoder().decode([RegistryEntry].self, from: data)
        guard let oracleEntry = entries.first(where: { entry in
            entry.services?.contains(where: { $0.name == "dpyc-oracle" }) ?? false
        }),
        let oracleService = oracleEntry.services?.first(where: { $0.name == "dpyc-oracle" }),
        let url = URL(string: oracleService.url) else {
            throw RegistryError.oracleNotFound
        }
        return url
    }
}

enum RegistryError: LocalizedError {
    case fetchFailed
    case oracleNotFound

    var errorDescription: String? {
        switch self {
        case .fetchFailed:
            return "Failed to fetch the DPYC community registry"
        case .oracleNotFound:
            return "Oracle service not found in the registry"
        }
    }
}
