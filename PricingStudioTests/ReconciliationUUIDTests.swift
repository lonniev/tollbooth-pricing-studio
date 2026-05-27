import XCTest
@testable import PricingStudio

/// Tests for the UUID-join Reconcile flow introduced with the
/// tollbooth-dpyc 0.38.0 / pricing-studio 1.10.0 refactor.
///
/// The wheel returns canonical (tool_id, mcp_name, category, intent)
/// via `list_canonical_identities`. Studio UUID-joins that against
/// the stored pricing model — no name-derived UUIDs, no local
/// computation, no repair-in-place. Renames in the operator's code
/// (function or capability label) leave UUIDs intact.
@MainActor
final class ReconciliationUUIDTests: XCTestCase {

    private func makeStoredModel(tools: [ToolPrice]) -> PricingModelResponse {
        PricingModelResponse(
            status: "ok",
            modelId: "test",
            name: "test",
            isActive: true,
            tools: tools,
            pipeline: nil,
            trancheLifetime: nil
        )
    }

    // MARK: - applyReconciliation: UUID-keyed merge

    /// A canonical row with a new UUID lands in localEdits as an addition.
    func testApplyReconciliationAddsNewTool() {
        let vm = PricingViewModel()

        let storedModel = makeStoredModel(tools: [])

        let newTool = ToolPrice(
            toolId: "fb5188ae-5792-54b8-bbd1-6b289605fa31",
            toolName: "brain_get_thought_by_name",
            priceSats: 0,
            priced: false,
            category: "read",
            intent: "Look up a thought by exact name."
        )

        let mismatch = MCPService.ToolMismatch(
            newIdentities: [MCPService.CanonicalIdentity(
                toolId: newTool.toolId,
                mcpName: newTool.toolName,
                category: newTool.category,
                intent: newTool.intent
            )],
            staleTools: [],
            matchedPairs: []
        )

        vm.applyReconciliation(
            suggestedTools: [newTool],
            mismatch: mismatch,
            storedModel: storedModel
        )

        XCTAssertNotNil(vm.localEdits[newTool.toolId])
        XCTAssertFalse(vm.localRemovals.contains(newTool.toolId))
    }

    /// A stored row whose UUID is no longer in the canonical inventory
    /// gets added to localRemovals.
    func testApplyReconciliationDropsStale() {
        let vm = PricingViewModel()

        let removed = ToolPrice(
            toolId: "00000000-1111-2222-3333-444444444444",
            toolName: "optionality_obsolete_tool",
            priceSats: 5,
            priced: true,
            category: "write",
            intent: "old"
        )

        let storedModel = makeStoredModel(tools: [removed])

        let mismatch = MCPService.ToolMismatch(
            newIdentities: [],
            staleTools: [removed],
            matchedPairs: []
        )

        vm.applyReconciliation(
            suggestedTools: [],
            mismatch: mismatch,
            storedModel: storedModel
        )

        XCTAssertTrue(vm.localRemovals.contains(removed.toolId))
        XCTAssertNil(vm.localEdits[removed.toolId])
    }

    /// A matched row whose display name drifted (operator renamed the
    /// MCP-exposed name) gets staged as an edit. The toolId is the same
    /// on both sides; only display fields change.
    func testApplyReconciliationStagesDriftedDisplay() {
        let vm = PricingViewModel()

        let stored = ToolPrice(
            toolId: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            toolName: "brain_get_thought_by_name",   // before rename
            priceSats: 5,
            priced: true,
            category: "read",
            intent: "Look up a thought by exact name."
        )

        let suggested = ToolPrice(
            toolId: stored.toolId,                     // same UUID
            toolName: "brain_lookup_node",             // operator renamed the function
            priceSats: 5,
            priced: true,
            category: "read",
            intent: "Look up a thought by exact name."
        )

        let storedModel = makeStoredModel(tools: [stored])

        let mismatch = MCPService.ToolMismatch(
            newIdentities: [],
            staleTools: [],
            matchedPairs: [(
                stored: stored,
                canonical: MCPService.CanonicalIdentity(
                    toolId: stored.toolId,
                    mcpName: suggested.toolName,
                    category: suggested.category,
                    intent: suggested.intent
                )
            )]
        )

        vm.applyReconciliation(
            suggestedTools: [suggested],
            mismatch: mismatch,
            storedModel: storedModel
        )

        // Renamed display: should be staged as an edit at the SAME UUID.
        XCTAssertNotNil(vm.localEdits[stored.toolId])
        XCTAssertEqual(vm.localEdits[stored.toolId]?.toolName, "brain_lookup_node")
        // Critically: NOT staged for removal — identity is preserved.
        XCTAssertFalse(vm.localRemovals.contains(stored.toolId))
    }

    /// A matched row with nothing changed produces no staged edit and no removal.
    func testApplyReconciliationIsNoopWhenUnchanged() {
        let vm = PricingViewModel()

        let stored = ToolPrice(
            toolId: "11111111-2222-3333-4444-555555555555",
            toolName: "brain_get_thought_by_name",
            priceSats: 5,
            priced: true,
            category: "read",
            intent: "unchanged"
        )

        let storedModel = makeStoredModel(tools: [stored])

        let mismatch = MCPService.ToolMismatch(
            newIdentities: [],
            staleTools: [],
            matchedPairs: [(
                stored: stored,
                canonical: MCPService.CanonicalIdentity(
                    toolId: stored.toolId,
                    mcpName: stored.toolName,
                    category: stored.category,
                    intent: stored.intent
                )
            )]
        )

        vm.applyReconciliation(
            suggestedTools: [stored],
            mismatch: mismatch,
            storedModel: storedModel
        )

        XCTAssertNil(vm.localEdits[stored.toolId])
        XCTAssertFalse(vm.localRemovals.contains(stored.toolId))
    }
}
