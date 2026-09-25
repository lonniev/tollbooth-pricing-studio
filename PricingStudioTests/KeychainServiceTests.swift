import Security
import XCTest
@testable import PricingStudio

/// nsec storage attributes are load-bearing for two shipped behaviors:
/// AfterFirstUnlock lets the LOCKED iPhone sign a watch-tap approval, and
/// Synchronizable carries the key between the owner's devices via iCloud
/// Keychain. These tests read the attributes back from the live (simulator)
/// Keychain — the same proof-by-read-back the app's migration uses.
final class KeychainServiceTests: XCTestCase {

    private let npub = "npub1keychaintestfixture000000000000000000000000000000000000000"
    private let nsec = "nsec1keychaintestfixturevalue00000000000000000000000000000000000"
    private let nsecService = "com.tollbooth.dpyc.PricingStudio.nsec"

    override func tearDown() {
        KeychainService.deleteNsec(forNpub: npub)
        super.tearDown()
    }

    private func nsecItemAttributes() -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: nsecService,
            kSecAttrAccount as String: npub,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? [String: Any]
    }

    /// Plant an item the way pre-sync builds stored it: a device-local,
    /// ThisDeviceOnly record.
    private func plantLegacyItem() {
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: nsecService,
            kSecAttrAccount as String: npub,
            kSecValueData as String: Data(nsec.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)
    }

    func testSaveStoresSynchronizableAfterFirstUnlock() throws {
        try KeychainService.saveNsec(nsec, forNpub: npub)

        let attrs = try XCTUnwrap(nsecItemAttributes())
        XCTAssertEqual(attrs[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlock as String)
        XCTAssertEqual((attrs[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue, true)
        XCTAssertEqual(KeychainService.loadNsec(forNpub: npub), nsec)
    }

    func testLoadAndDeleteReachLegacyLocalItems() {
        plantLegacyItem()

        XCTAssertEqual(KeychainService.loadNsec(forNpub: npub), nsec,
                       "load must match pre-sync (non-synchronizable) items")
        KeychainService.deleteNsec(forNpub: npub)
        XCTAssertNil(KeychainService.loadNsec(forNpub: npub),
                     "delete must remove pre-sync items too")
    }

    func testResaveReplacesLegacyItemWithoutDuplicating() throws {
        plantLegacyItem()

        try KeychainService.saveNsec(nsec, forNpub: npub)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: nsecService,
            kSecAttrAccount as String: npub,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let items = try XCTUnwrap(result as? [[String: Any]])
        XCTAssertEqual(items.count, 1, "re-save must replace the legacy item, not shadow it")
        XCTAssertEqual((items[0][kSecAttrSynchronizable as String] as? NSNumber)?.boolValue, true)
    }

    @MainActor
    func testEnsureNsecAccessibilityMigratesLegacyItem() throws {
        plantLegacyItem()

        KeychainService.ensureNsecAccessibility()

        let attrs = try XCTUnwrap(nsecItemAttributes())
        XCTAssertEqual(attrs[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlock as String)
        XCTAssertEqual((attrs[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue, true)
        XCTAssertEqual(KeychainService.loadNsec(forNpub: npub), nsec, "value survives migration")
    }

    @MainActor
    func testEnsureNsecAccessibilityLeavesCurrentItemAlone() throws {
        try KeychainService.saveNsec(nsec, forNpub: npub)
        let before = try XCTUnwrap(nsecItemAttributes())

        KeychainService.ensureNsecAccessibility()

        let after = try XCTUnwrap(nsecItemAttributes())
        XCTAssertEqual(before[kSecAttrModificationDate as String] as? Date,
                       after[kSecAttrModificationDate as String] as? Date,
                       "already-correct items must not be rewritten")
    }

    // MARK: - OpenRouter key + legacy Anthropic/xAI migration (issue #161)

    private let openRouterService = "com.tollbooth.dpyc.PricingStudio.openrouter"
    private let legacyAnthropicService = "com.tollbooth.dpyc.PricingStudio.anthropic"
    private let legacyXAIService = "com.tollbooth.dpyc.PricingStudio.xai"
    private let apiKeyAccount = "api-key"
    private let migrationFlag = "com.tollbooth.dpyc.PricingStudio.migratedOpenRouterAPIKey.v1"
    private let migrationDefaultsSuite = "KeychainServiceTests.OpenRouterMigration"

    private func deleteKey(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: apiKeyAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func plantLegacyKey(service: String, value: String) {
        deleteKey(service: service)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: apiKeyAccount,
            kSecValueData as String: Data(value.utf8),
        ]
        XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)
    }

    private func loadKey(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: apiKeyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func testOpenRouterAPIKeyRoundTrip() throws {
        deleteKey(service: openRouterService)
        defer {
            KeychainService.deleteOpenRouterAPIKey()
        }

        try KeychainService.saveOpenRouterAPIKey("sk-or-test-key")
        XCTAssertEqual(KeychainService.loadOpenRouterAPIKey(), "sk-or-test-key")
        KeychainService.deleteOpenRouterAPIKey()
        XCTAssertNil(KeychainService.loadOpenRouterAPIKey())
    }

    func testMigrateLegacyProviderAPIKeysRemovesOldSlotsOnce() {
        let defaults = UserDefaults(suiteName: "\(migrationDefaultsSuite).\(UUID().uuidString)")!
        defaults.removeObject(forKey: migrationFlag)

        plantLegacyKey(service: legacyAnthropicService, value: "sk-ant-legacy")
        plantLegacyKey(service: legacyXAIService, value: "xai-legacy")
        XCTAssertEqual(loadKey(service: legacyAnthropicService), "sk-ant-legacy")
        XCTAssertEqual(loadKey(service: legacyXAIService), "xai-legacy")

        KeychainService.migrateLegacyProviderAPIKeysIfNeeded(defaults: defaults)

        XCTAssertNil(loadKey(service: legacyAnthropicService), "Anthropic key deleted on migration")
        XCTAssertNil(loadKey(service: legacyXAIService), "xAI key deleted on migration")
        XCTAssertTrue(defaults.bool(forKey: migrationFlag))

        // Re-plant and migrate again — latch must prevent a second delete cycle
        // from being "required", but a second call is a no-op on the latch.
        plantLegacyKey(service: legacyAnthropicService, value: "sk-ant-replanted")
        KeychainService.migrateLegacyProviderAPIKeysIfNeeded(defaults: defaults)
        XCTAssertEqual(loadKey(service: legacyAnthropicService), "sk-ant-replanted",
                       "second migrate is a no-op once the latch is set")
        deleteKey(service: legacyAnthropicService)
        deleteKey(service: legacyXAIService)
    }
}
