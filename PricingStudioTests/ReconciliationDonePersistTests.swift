import XCTest
@testable import PricingStudio

/// Tests for issue #114: the Reconcile dialog now persists directly on Done.
///
/// `ReconciliationSheet.finish()` (invoked by both the toolbar Done and the
/// applied-phase Done) stages any reconciliation the user has not yet tapped
/// Apply on, then calls `onDone` to save straight to the operator's pricing
/// model. `pendingReconciliation` is the pure decision at the heart of that
/// flow: what — if anything — Done must stage before it persists.
@MainActor
final class ReconciliationDonePersistTests: XCTestCase {

    private func makeMismatch(new: [ToolPrice]) -> MCPService.ToolMismatch {
        MCPService.ToolMismatch(
            newIdentities: new.map {
                MCPService.CanonicalIdentity(
                    toolId: $0.toolId,
                    mcpName: $0.toolName,
                    category: $0.category,
                    intent: $0.intent
                )
            },
            staleTools: [],
            matchedPairs: []
        )
    }

    private func makeTool() -> ToolPrice {
        ToolPrice(
            toolId: "fb5188ae-5792-54b8-bbd1-6b289605fa31",
            toolName: "brain_get_thought_by_name",
            priceSats: 0,
            priced: false,
            category: "read",
            intent: "Look up a thought by exact name."
        )
    }

    /// Done tapped on a reviewed-but-not-applied result must stage that result
    /// (so the subsequent persist saves it), not silently save nothing.
    func testDoneStagesPendingReviewWhenApplyNotTapped() {
        let tool = makeTool()
        let mismatch = makeMismatch(new: [tool])

        let pending = ReconciliationSheet.pendingReconciliation(
            applied: false,
            suggested: [tool],
            mismatch: mismatch
        )

        XCTAssertNotNil(pending, "Done must stage the reviewed reconciliation")
        XCTAssertEqual(pending?.suggested.first?.toolId, tool.toolId)
    }

    /// Once Apply has already staged (`applied == true`), Done must not
    /// re-stage — it just persists what is already staged.
    func testDoneDoesNotRestageAfterApply() {
        let tool = makeTool()
        let mismatch = makeMismatch(new: [tool])

        let pending = ReconciliationSheet.pendingReconciliation(
            applied: true,
            suggested: [tool],
            mismatch: mismatch
        )

        XCTAssertNil(pending)
    }

    /// With no reconciled result on screen there is nothing for Done to stage.
    func testDoneStagesNothingWithoutAReviewedResult() {
        XCTAssertNil(
            ReconciliationSheet.pendingReconciliation(
                applied: false,
                suggested: nil,
                mismatch: nil
            )
        )
    }

    /// End-to-end of the staging half of Done: staging the pending result
    /// lands the new tool in `localEdits`, exactly what `savePricing` then
    /// persists to Neon.
    func testDonePathStagesEditsForPersist() {
        let vm = PricingViewModel()
        let tool = makeTool()
        let mismatch = makeMismatch(new: [tool])
        let storedModel = PricingModelResponse(
            status: "ok",
            modelId: "test",
            name: "test",
            isActive: true,
            tools: [],
            trancheLifetime: nil
        )

        // What finish() does before calling onDone/savePricing.
        if let pending = ReconciliationSheet.pendingReconciliation(
            applied: false,
            suggested: [tool],
            mismatch: mismatch
        ) {
            vm.applyReconciliation(
                suggestedTools: pending.suggested,
                mismatch: pending.mismatch,
                storedModel: storedModel
            )
        }

        XCTAssertNotNil(vm.localEdits[tool.toolId])
    }
}
