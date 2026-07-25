import XCTest
@testable import PricingStudio

/// Pins the two testable seams of the Persistence Status follow-up (#116):
///
/// 1. The section is presented with the plain-language title "Persistence
///    Status", never the operator-internal jargon "Network Books Health".
/// 2. When the Neon control plane is unconfigured, the panel offers a
///    Secure Courier control that reuses the SAME `onRequestCourier` path as
///    Operator Secrets, targeting the `NEON_API_KEY` secret — not a parallel
///    flow. `AuthorityDetailView.neonKeysCourierParams` is that seam.
///
/// Layout/width parity is a runtime SwiftUI concern verified visually on a
/// wide iPad layout (see the PR's human-in-the-loop note), so it is not
/// unit-pinned here.
final class PersistenceStatusCourierTests: XCTestCase {

    /// The user-facing title is the plain rename, with none of the old jargon.
    func testSectionTitleIsPersistenceStatusNotJargon() {
        XCTAssertEqual(AuthorityDetailView.persistenceStatusTitle, "Persistence Status")
        XCTAssertNotEqual(AuthorityDetailView.persistenceStatusTitle, "Network Books Health")
    }

    /// The courier request targets BOTH Neon secrets — the organization id and
    /// the org-scoped API key (an org key's /projects call needs org_id) — and
    /// carries the Authority's identity, endpoint, and credential service through
    /// to the shared courier sheet, landing the user in the identical flow.
    func testNeonKeysCourierParamsTargetsBothNeonSecrets() throws {
        let url = try XCTUnwrap(URL(string: "https://authority.example/mcp"))
        let params = AuthorityDetailView.neonKeysCourierParams(
            authorityName: "Prime Authority",
            authorityNpub: "npub1authorityaaa",
            endpointURL: url,
            credentialService: "authority-vault"
        )

        XCTAssertEqual(params.missingSecrets, ["NEON_ORG_ID", "NEON_API_KEY"])
        XCTAssertEqual(params.operatorName, "Prime Authority")
        XCTAssertEqual(params.operatorNpub, "npub1authorityaaa")
        XCTAssertEqual(params.endpointURL, url)
        XCTAssertEqual(params.credentialService, "authority-vault")
    }
}
