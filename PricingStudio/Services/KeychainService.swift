import Foundation
import Security

enum KeychainService {

    private static let tokenService = "com.tollbooth.dpyc.PricingStudio"
    private static let bundleService = "com.tollbooth.dpyc.PricingStudio.bundle"
    private static let nsecService = "com.tollbooth.dpyc.PricingStudio.nsec"

    // MARK: - Token Bundle Storage (preferred)

    static func saveTokenBundle(_ bundle: TokenBundle, forOperator key: String) throws {
        let data = try JSONEncoder().encode(bundle)
        try save(data: data, service: bundleService, account: key)
        // Also save bare token for backward compat with any code reading the old key
        try save(data: Data(bundle.accessToken.utf8), service: tokenService, account: key)
    }

    static func loadTokenBundle(forOperator key: String) -> TokenBundle? {
        guard let data = loadData(service: bundleService, account: key) else { return nil }
        return try? JSONDecoder().decode(TokenBundle.self, from: data)
    }

    static func deleteTokenBundle(forOperator key: String) {
        delete(service: bundleService, account: key)
        delete(service: tokenService, account: key)
    }

    // MARK: - Legacy OAuth Token Storage

    static func saveToken(_ token: String, forOperator npub: String) throws {
        try save(data: Data(token.utf8), service: tokenService, account: npub)
    }

    static func loadToken(forOperator npub: String) -> String? {
        load(service: tokenService, account: npub)
    }

    static func deleteToken(forOperator npub: String) {
        delete(service: tokenService, account: npub)
    }

    // MARK: - nsec Storage

    static func saveNsec(_ nsec: String, forNpub npub: String) throws {
        try save(data: Data(nsec.utf8), service: nsecService, account: npub)
    }

    static func loadNsec(forNpub npub: String) -> String? {
        load(service: nsecService, account: npub)
    }

    static func deleteNsec(forNpub npub: String) {
        delete(service: nsecService, account: npub)
    }

    // MARK: - Generic Keychain Operations

    private static func save(data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    private static func loadData(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
    }

    private static func load(service: String, account: String) -> String? {
        guard let data = loadData(service: service, account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Keychain save failed with status \(status)"
        }
    }
}
