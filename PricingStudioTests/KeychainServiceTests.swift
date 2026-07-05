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
}
