import XCTest
@testable import PricingStudio

/// Regression coverage for the UUID-derivation bug that bit Optionality's
/// `share_entry` (and `send_patron_dm` before it).
///
/// Studio's old Reconcile derived `toolId` from the slug-prefixed MCP
/// name (e.g. "optionality_share_entry"). The wheel's `paid_tool`
/// decorator uses `capability_uuid(<bare capability>)` for the lookup.
/// The two UUIDs differ, the row is unreachable, and the wheel returns
/// "Tool '…' is not yet in the pricing model."
///
/// Reference UUIDs computed by Python's
/// `uuid.uuid5(DPYC_NAMESPACE, capability)` with the wheel's namespace
/// `d9a3f1c7-4e2b-4a8f-b6d5-1c3e7f9a2b4d`:
///   share_entry              -> 6accf6b4-617e-5727-9337-1df52729c116
///   optionality_share_entry  -> aca27ddc-8076-5bb7-8e71-8a5c5c61246b
///   judge_trade              -> 2d4f4988-8199-5753-9ed2-17f458b0d17a
///   import_csv               -> e4abda05-bce0-5d22-bd62-2db18bb7afe0
@MainActor
final class ReconciliationUUIDTests: XCTestCase {

    // MARK: - Cross-language UUID parity

    /// Capability UUID derivation must match the wheel's Python
    /// `capability_uuid()` byte-for-byte. Hardcoded reference values
    /// catch any future drift in the SHA-1 / variant-byte logic.
    func testCapabilityUUIDMatchesPythonReference() {
        XCTAssertEqual(
            ToolPrice.capabilityUUID("share_entry"),
            "6accf6b4-617e-5727-9337-1df52729c116"
        )
        XCTAssertEqual(
            ToolPrice.capabilityUUID("optionality_share_entry"),
            "aca27ddc-8076-5bb7-8e71-8a5c5c61246b"
        )
        XCTAssertEqual(
            ToolPrice.capabilityUUID("judge_trade"),
            "2d4f4988-8199-5753-9ed2-17f458b0d17a"
        )
    }

    // MARK: - bareCapability helper

    func testBareCapabilityStripsKnownSlug() {
        let vm = ReconciliationViewModel()
        vm.setSlugForTesting("optionality")
        XCTAssertEqual(vm.bareCapability("optionality_share_entry"), "share_entry")
        XCTAssertEqual(vm.bareCapability("optionality_deal_scenario"), "deal_scenario")
    }

    func testBareCapabilityLeavesNonPrefixedNamesAlone() {
        let vm = ReconciliationViewModel()
        vm.setSlugForTesting("optionality")
        // Wheel built-ins are namespaced the same way; defensive: if a
        // tool ever ships without the operator prefix, leave it alone.
        XCTAssertEqual(vm.bareCapability("check_balance"), "check_balance")
        XCTAssertEqual(vm.bareCapability("share_entry"), "share_entry")
    }

    func testBareCapabilityIsIdentityWithoutSlug() {
        let vm = ReconciliationViewModel()
        // No slug set — every name is treated as already-bare.
        XCTAssertEqual(vm.bareCapability("optionality_share_entry"), "optionality_share_entry")
        XCTAssertEqual(vm.bareCapability("share_entry"), "share_entry")
    }

    // MARK: - canonicalToolId produces the wheel-facing UUID

    func testCanonicalToolIdMatchesWheelLookup() {
        let vm = ReconciliationViewModel()
        vm.setSlugForTesting("optionality")
        // The whole point: feeding the protocol-visible MCP name in
        // produces the canonical UUID the wheel computes from the bare
        // capability — NOT the orphan UUID the old Reconcile produced.
        XCTAssertEqual(
            vm.canonicalToolId(forMCPName: "optionality_share_entry"),
            "6accf6b4-617e-5727-9337-1df52729c116"
        )
        XCTAssertNotEqual(
            vm.canonicalToolId(forMCPName: "optionality_share_entry"),
            "aca27ddc-8076-5bb7-8e71-8a5c5c61246b"
        )
    }

    // MARK: - Orphan detection

    /// A row whose stored toolId differs from the canonical UUID must
    /// be flagged as an orphan. The bug the user reported: detection
    /// silently said "everything is fine" when names matched but UUIDs
    /// didn't.
    func testOrphanRowIsDetected() {
        let vm = ReconciliationViewModel()
        vm.setSlugForTesting("optionality")

        // Simulate the pre-1.9.2 Reconcile artifact: tool stored under
        // the slug-prefixed UUID.
        let orphan = ToolPrice(
            toolId: "aca27ddc-8076-5bb7-8e71-8a5c5c61246b", // capabilityUUID("optionality_share_entry")
            toolName: "optionality_share_entry",
            priceSats: 0,
            priced: true,
            category: "write",
            intent: "share"
        )

        // Canonical (correct) row for comparison.
        let healthy = ToolPrice(
            toolId: "2d4f4988-8199-5753-9ed2-17f458b0d17a", // capabilityUUID("judge_trade")
            toolName: "optionality_judge_trade",
            priceSats: 50,
            priced: true,
            category: "write",
            intent: "judge"
        )

        XCTAssertNotEqual(orphan.toolId, vm.canonicalToolId(forMCPName: orphan.toolName),
                          "Orphan must not match canonical — that's what makes it an orphan.")
        XCTAssertEqual(healthy.toolId, vm.canonicalToolId(forMCPName: healthy.toolName),
                       "Healthy row's stored UUID must match the canonical one.")
    }
}

// MARK: - Test-only seam

extension ReconciliationViewModel {
    /// Test seam — production code sets the slug via `detectMismatch()`.
    /// Marked `_TEST_` so it's obvious at call sites that this is not
    /// for app use.
    func setSlugForTesting(_ slug: String) {
        // Reach the private property via a same-module helper. We
        // expose a setter here instead of widening the visibility of
        // the stored property itself.
        self._setOperatorSlug(slug)
    }
}
