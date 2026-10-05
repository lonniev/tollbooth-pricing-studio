import XCTest
@testable import PricingStudioCore

/// Pins the Operator Secrets rotation planner (issue #153).
///
/// Before this change the Operator Secrets card gated Deliver on
/// `hasMissing`, so a healthy operator (`missing: []`) could only Forget.
/// These tests lock the three rules the UI must obey:
///
/// 1. Missing secrets → Deliver mode, every missing secret selected.
/// 2. Fully configured → Rotate mode, default selection empty (accidental
///    send does nothing).
/// 3. Rotate emits only ticked configured secrets; unknown ticks are dropped.
final class OperatorSecretRotationTests: XCTestCase {

    private let btcpay = OperatorSecretRotation.Field(
        key: "btcpay_api_key", category: "secret", isConfigured: true
    )
    private let github = OperatorSecretRotation.Field(
        key: "github_token", category: "secret", isConfigured: true
    )
    private let neon = OperatorSecretRotation.Field(
        key: "neon_api_key", category: "secret", isConfigured: true
    )
    private let missingBTCPay = OperatorSecretRotation.Field(
        key: "btcpay_api_key", category: "secret", isConfigured: false
    )
    private let authorityLink = OperatorSecretRotation.Field(
        key: "authority_npub", category: "authority", isConfigured: true
    )

    // MARK: - Deliver mode

    func testDeliverWhenAnythingMissing() {
        let plan = OperatorSecretRotation.plan(
            configured: [github],
            missing: [missingBTCPay],
            optionalMissing: []
        )
        XCTAssertEqual(plan.mode, .deliver)
        XCTAssertEqual(plan.buttonLabel, "Deliver")
        XCTAssertEqual(plan.selectedKeys, ["btcpay_api_key"])
        XCTAssertTrue(plan.canBegin)
        XCTAssertEqual(plan.candidates.map(\.key), ["btcpay_api_key"])
    }

    func testDeliverIncludesOptionalMissingSecrets() {
        let optional = OperatorSecretRotation.Field(
            key: "optional_llm_key", category: "secret", isConfigured: false
        )
        let plan = OperatorSecretRotation.plan(
            configured: [github],
            missing: [],
            optionalMissing: [optional]
        )
        XCTAssertEqual(plan.mode, .deliver)
        XCTAssertEqual(plan.selectedKeys, ["optional_llm_key"])
        XCTAssertTrue(plan.canBegin)
    }

    func testDeliverIgnoresUserSelection() {
        // Even if the steward ticks something else, deliver always ships the
        // missing set — the operator cannot come online without them.
        let plan = OperatorSecretRotation.plan(
            configured: [],
            missing: [missingBTCPay],
            selectedKeys: ["github_token"]
        )
        XCTAssertEqual(plan.selectedKeys, ["btcpay_api_key"])
    }

    // MARK: - Rotate mode

    func testRotateWhenFullyConfiguredDefaultsToNothingSelected() {
        let plan = OperatorSecretRotation.plan(
            configured: [btcpay, github, neon],
            missing: [],
            optionalMissing: []
        )
        XCTAssertEqual(plan.mode, .rotate)
        XCTAssertEqual(plan.buttonLabel, "Rotate")
        XCTAssertEqual(plan.selectedKeys, [], "default selection must be empty")
        XCTAssertFalse(plan.canBegin, "accidental send must do nothing")
        XCTAssertEqual(plan.candidates.map(\.key), ["btcpay_api_key", "github_token", "neon_api_key"])
    }

    func testRotateEmitsOnlyTickedConfiguredSecrets() {
        let plan = OperatorSecretRotation.plan(
            configured: [btcpay, github, neon],
            missing: [],
            selectedKeys: ["btcpay_api_key", "neon_api_key"]
        )
        XCTAssertEqual(plan.mode, .rotate)
        XCTAssertEqual(plan.selectedKeys, ["btcpay_api_key", "neon_api_key"])
        XCTAssertTrue(plan.canBegin)
    }

    func testRotateDropsUnknownAndNonSecretTicks() {
        let plan = OperatorSecretRotation.plan(
            configured: [btcpay, github, authorityLink],
            missing: [],
            selectedKeys: ["btcpay_api_key", "not_a_real_field", "authority_npub"]
        )
        // authority_npub is category "authority", not a secret candidate.
        XCTAssertEqual(plan.selectedKeys, ["btcpay_api_key"])
        XCTAssertEqual(plan.candidates.map(\.key), ["btcpay_api_key", "github_token"])
    }

    func testSingleFieldRotationHelper() {
        let plan = OperatorSecretRotation.planSingleRotation(
            fieldKey: "github_token",
            configured: [btcpay, github, neon]
        )
        XCTAssertEqual(plan.mode, .rotate)
        XCTAssertEqual(plan.selectedKeys, ["github_token"])
        XCTAssertTrue(plan.canBegin)
        XCTAssertEqual(
            OperatorSecretRotation.courierSecretLabels(for: plan),
            ["Github Token"]
        )
    }

    func testSingleFieldRotationOfUnknownKeyCannotBegin() {
        let plan = OperatorSecretRotation.planSingleRotation(
            fieldKey: "nope",
            configured: [btcpay]
        )
        XCTAssertEqual(plan.selectedKeys, [])
        XCTAssertFalse(plan.canBegin)
    }

    // MARK: - Non-secret fields stay out of the courier

    func testNonSecretConfiguredFieldsAreNotRotateCandidates() {
        let plan = OperatorSecretRotation.plan(
            configured: [authorityLink, btcpay],
            missing: []
        )
        XCTAssertEqual(plan.candidates.map(\.key), ["btcpay_api_key"])
    }

    // MARK: - Copy

    func testRotateCopyNeverDemandsAllFieldsFilled() {
        let ready = OperatorSecretRotation.readyCopy(mode: .rotate)
        let failed = OperatorSecretRotation.collectFailedCopy(mode: .rotate, poison: "amber fox")
        XCTAssertFalse(ready.lowercased().contains("all fields"))
        XCTAssertFalse(failed.lowercased().contains("all fields"))
        XCTAssertTrue(ready.lowercased().contains("omit") || ready.lowercased().contains("only"))
        XCTAssertTrue(failed.contains("amber fox"))
    }

    func testExplainCopyNamesOperator() {
        let deliver = OperatorSecretRotation.explainCopy(mode: .deliver, operatorName: "Acme")
        let rotate = OperatorSecretRotation.explainCopy(mode: .rotate, operatorName: "Acme")
        XCTAssertTrue(deliver.contains("Acme"))
        XCTAssertTrue(rotate.contains("Acme"))
        XCTAssertTrue(rotate.lowercased().contains("rotate") || rotate.lowercased().contains("omit"))
    }

    // MARK: - Labels

    func testFieldLabelHumanizesSnakeCase() {
        XCTAssertEqual(
            OperatorSecretRotation.fieldLabel("btcpay_api_key"),
            "Btcpay Api Key"
        )
    }
}
