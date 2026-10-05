import XCTest
@testable import PricingStudio
import PricingStudioCore

/// Pins the Operator Secrets UI seams for issue #153.
///
/// Before: Deliver was gated on `hasMissing`, so a healthy operator
/// (`missing: []`, six green ticks) could only Forget. After: the static
/// planner on `AuthorityDetailView` exposes Deliver when secrets are missing
/// and Rotate (default selection empty) when they are not, and
/// `secretsCourierParams` carries the mode into the shared courier card so
/// rotate copy never says "fill all fields".
final class OperatorSecretsRotationTests: XCTestCase {

    // MARK: - Fixtures

    private func field(
        _ key: String,
        category: String = "secret",
        status: String = "configured"
    ) -> MCPService.OnboardingField {
        MCPService.OnboardingField(
            field: key,
            category: category,
            status: status
        )
    }

    private func status(
        configured: [MCPService.OnboardingField] = [],
        missing: [MCPService.OnboardingField] = [],
        optionalMissing: [MCPService.OnboardingField] = [],
        ready: Bool = false,
        service: String = "operator-vault"
    ) -> MCPService.OnboardingStatus {
        MCPService.OnboardingStatus(
            ready: ready,
            configured: configured,
            missing: missing,
            optionalMissing: optionalMissing,
            summary: "test",
            credentialService: service
        )
    }

    // MARK: - The defect this issue reports

    /// A fully-configured operator used to have no courier door. The planner
    /// must now return Rotate mode with an empty default selection so the UI
    /// can offer Rotate without auto-sending anything.
    func testHealthyOperatorPlansRotateWithEmptyDefaultSelection() {
        let st = status(
            configured: [
                field("btcpay_api_key"),
                field("github_token"),
                field("neon_api_key"),
            ],
            ready: true
        )
        let plan = AuthorityDetailView.secretPlan(for: st)
        XCTAssertEqual(plan.mode, .rotate)
        XCTAssertEqual(plan.buttonLabel, "Rotate")
        XCTAssertEqual(plan.selectedKeys, [])
        XCTAssertFalse(plan.canBegin, "accidental send must do nothing")
        XCTAssertEqual(
            plan.candidates.map(\.key),
            ["btcpay_api_key", "github_token", "neon_api_key"]
        )
    }

    /// Missing secrets still Deliver — the original path must keep working.
    func testMissingSecretsStillPlanDeliver() {
        let st = status(
            configured: [field("github_token")],
            missing: [field("btcpay_api_key", status: "missing")],
            ready: false
        )
        let plan = AuthorityDetailView.secretPlan(for: st)
        XCTAssertEqual(plan.mode, .deliver)
        XCTAssertEqual(plan.buttonLabel, "Deliver")
        XCTAssertEqual(plan.selectedKeys, ["btcpay_api_key"])
        XCTAssertTrue(plan.canBegin)
    }

    // MARK: - Courier params

    func testRotateCourierParamsCarryModeAndOnlyTickedLabels() throws {
        let st = status(
            configured: [
                field("btcpay_api_key"),
                field("github_token"),
            ],
            ready: true
        )
        let plan = AuthorityDetailView.secretPlan(
            for: st,
            selectedKeys: ["btcpay_api_key"]
        )
        let url = try XCTUnwrap(URL(string: "https://op.example/mcp"))
        let params = AuthorityDetailView.secretsCourierParams(
            authorityName: "Acme",
            authorityNpub: "npub1acme",
            endpointURL: url,
            credentialService: "operator-vault",
            plan: plan
        )
        XCTAssertEqual(params.mode, .rotate)
        XCTAssertEqual(params.missingSecrets, ["Btcpay Api Key"])
        XCTAssertEqual(params.operatorName, "Acme")
        XCTAssertEqual(params.credentialService, "operator-vault")
        // Rotate copy must never demand every field be filled.
        let ready = OperatorSecretRotation.readyCopy(mode: params.mode)
        XCTAssertFalse(ready.lowercased().contains("all fields"))
    }

    func testDeliverCourierParamsListEveryMissingSecret() throws {
        let st = status(
            missing: [
                field("btcpay_api_key", status: "missing"),
                field("github_token", status: "missing"),
            ]
        )
        let plan = AuthorityDetailView.secretPlan(for: st)
        let url = try XCTUnwrap(URL(string: "https://op.example/mcp"))
        let params = AuthorityDetailView.secretsCourierParams(
            authorityName: "Acme",
            authorityNpub: "npub1acme",
            endpointURL: url,
            credentialService: "operator-vault",
            plan: plan
        )
        XCTAssertEqual(params.mode, .deliver)
        XCTAssertEqual(params.missingSecrets, ["Btcpay Api Key", "Github Token"])
    }

    /// Per-row Rotate: ticking one configured secret produces a single-field plan.
    func testSingleFieldRotatePlan() {
        let st = status(
            configured: [
                field("btcpay_api_key"),
                field("github_token"),
                field("neon_api_key"),
            ],
            ready: true
        )
        let plan = AuthorityDetailView.secretPlan(
            for: st,
            selectedKeys: ["github_token"]
        )
        XCTAssertEqual(plan.mode, .rotate)
        XCTAssertEqual(plan.selectedKeys, ["github_token"])
        XCTAssertTrue(plan.canBegin)
    }

    /// Non-secret configured fields (authority links, etc.) are not rotate candidates.
    func testNonSecretFieldsExcludedFromRotateCandidates() {
        let st = status(
            configured: [
                field("authority_npub", category: "authority"),
                field("btcpay_api_key"),
            ],
            ready: true
        )
        let plan = AuthorityDetailView.secretPlan(for: st)
        XCTAssertEqual(plan.candidates.map(\.key), ["btcpay_api_key"])
    }
}
