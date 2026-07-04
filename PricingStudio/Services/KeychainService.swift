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

    // MARK: - Patron-Scoped Token Bundle Storage

    private static let patronBundleService = "com.tollbooth.dpyc.PricingStudio.patron.bundle"

    static func saveTokenBundle(_ bundle: TokenBundle, forPatron patronNpub: String, operator operatorHost: String) throws {
        let key = "oauth-token-\(patronNpub)-\(operatorHost)"
        let data = try JSONEncoder().encode(bundle)
        try save(data: data, service: patronBundleService, account: key)
    }

    static func loadTokenBundle(forPatron patronNpub: String, operator operatorHost: String) -> TokenBundle? {
        let key = "oauth-token-\(patronNpub)-\(operatorHost)"
        guard let data = loadData(service: patronBundleService, account: key) else { return nil }
        return try? JSONDecoder().decode(TokenBundle.self, from: data)
    }

    static func deleteTokenBundle(forPatron patronNpub: String, operator operatorHost: String) {
        let key = "oauth-token-\(patronNpub)-\(operatorHost)"
        delete(service: patronBundleService, account: key)
    }

    // MARK: - nsec Storage

    /// nsecs are stored AfterFirstUnlockThisDeviceOnly (not the WhenUnlocked
    /// default): the Wrist Approval notification action must sign a reply on
    /// the LOCKED iPhone when the user taps Approve on the mirrored watch
    /// banner. ThisDeviceOnly keeps the key out of backups and device
    /// transfers — a new device requires re-entering the nsec.
    static func saveNsec(_ nsec: String, forNpub npub: String) throws {
        try save(
            data: Data(nsec.utf8),
            service: nsecService,
            account: npub,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    }

    static func loadNsec(forNpub npub: String) -> String? {
        load(service: nsecService, account: npub)
    }

    static func deleteNsec(forNpub npub: String) {
        delete(service: nsecService, account: npub)
    }

    /// One-time migration of pre-existing nsec items (saved under the
    /// WhenUnlocked default) to AfterFirstUnlockThisDeviceOnly. Re-saving is
    /// the only reliable way to change kSecAttrAccessible (SecItemUpdate
    /// can't), and it requires the device to be unlocked — call this from
    /// foreground startup only. The flag latches only when every item
    /// migrated, so a partial failure retries next launch.
    @MainActor
    static func migrateNsecAccessibility() {
        let migratedKey = "keychain.nsecAccessibilityMigrated.v1"
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: nsecService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            UserDefaults.standard.set(true, forKey: migratedKey)
            return
        }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            TrafficLogger.shared.log(.error, label: "Keychain Migrate", detail: "nsec enumeration failed (status \(status)); will retry next launch")
            return
        }

        var allMigrated = true
        for item in items {
            guard let npub = item[kSecAttrAccount as String] as? String else { continue }
            guard let nsec = loadNsec(forNpub: npub) else {
                allMigrated = false
                TrafficLogger.shared.log(.error, label: "Keychain Migrate", detail: "\(npub.prefix(12))… unreadable; will retry next launch")
                continue
            }
            do {
                try saveNsec(nsec, forNpub: npub)
                TrafficLogger.shared.log(.inbound, label: "Keychain Migrate", detail: "\(npub.prefix(12))… nsec now AfterFirstUnlockThisDeviceOnly", npub: npub)
            } catch {
                allMigrated = false
                TrafficLogger.shared.log(.error, label: "Keychain Migrate", detail: "\(npub.prefix(12))… re-save failed: \(error.localizedDescription)")
            }
        }
        if allMigrated {
            UserDefaults.standard.set(true, forKey: migratedKey)
        }
    }

    // MARK: - Anthropic API Key Storage

    private static let anthropicService = "com.tollbooth.dpyc.PricingStudio.anthropic"
    private static let anthropicAccount = "api-key"

    static func saveAnthropicAPIKey(_ key: String) throws {
        try save(data: Data(key.utf8), service: anthropicService, account: anthropicAccount)
    }

    static func loadAnthropicAPIKey() -> String? {
        load(service: anthropicService, account: anthropicAccount)
    }

    static func deleteAnthropicAPIKey() {
        delete(service: anthropicService, account: anthropicAccount)
    }

    // MARK: - xAI API Key Storage

    private static let xaiService = "com.tollbooth.dpyc.PricingStudio.xai"
    private static let xaiAccount = "api-key"

    static func saveXAIAPIKey(_ key: String) throws {
        try save(data: Data(key.utf8), service: xaiService, account: xaiAccount)
    }

    static func loadXAIAPIKey() -> String? {
        load(service: xaiService, account: xaiAccount)
    }

    static func deleteXAIAPIKey() {
        delete(service: xaiService, account: xaiAccount)
    }

    // MARK: - Credential Cards (ncred)

    private static let ncredService = "com.tollbooth.ncred"

    /// Save an ncred credential card keyed by patron+service+operator.
    static func saveNcred(_ ncred: String, forPatron patronNpub: String, service: String, operator operatorNpub: String) throws {
        let account = "\(patronNpub):\(service):\(operatorNpub)"
        try save(data: Data(ncred.utf8), service: ncredService, account: account)
    }

    /// Load a saved ncred for a patron+service+operator triple.
    static func loadNcred(forPatron patronNpub: String, service: String, operator operatorNpub: String) -> String? {
        let account = "\(patronNpub):\(service):\(operatorNpub)"
        return load(service: ncredService, account: account)
    }

    /// Delete a saved ncred.
    static func deleteNcred(forPatron patronNpub: String, service: String, operator operatorNpub: String) {
        let account = "\(patronNpub):\(service):\(operatorNpub)"
        delete(service: ncredService, account: account)
    }

    // MARK: - Proof Token Storage (poison-keyed npub proof)

    private static let proofTokenService = "com.tollbooth.dpyc.PricingStudio.proof_token"

    /// Save a poison proof token for a patron+operator pair.
    static func saveProofToken(_ token: String, forPatron patronNpub: String, operator operatorHost: String) throws {
        let account = "\(patronNpub):\(operatorHost)"
        try save(data: Data(token.utf8), service: proofTokenService, account: account)
    }

    /// Load a saved proof token for a patron+operator pair.
    static func loadProofToken(forPatron patronNpub: String, operator operatorHost: String) -> String? {
        let account = "\(patronNpub):\(operatorHost)"
        return load(service: proofTokenService, account: account)
    }

    /// Delete a saved proof token.
    static func deleteProofToken(forPatron patronNpub: String, operator operatorHost: String) {
        let account = "\(patronNpub):\(operatorHost)"
        delete(service: proofTokenService, account: account)
    }

    // MARK: - Generic Keychain Operations

    private static func save(data: Data, service: String, account: String, accessible: CFString? = nil) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        if let accessible {
            addQuery[kSecAttrAccessible as String] = accessible
        }
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
