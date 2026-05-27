import Foundation
import OSLog

private let logger = Logger(subsystem: "com.tollbooth.dpyc.PricingStudio", category: "Reconciliation")

/// Reconciles the stored pricing model in Neon against the wheel's
/// canonical inventory (returned by `list_canonical_identities`).
///
/// Everything is UUID-joined. Studio does not derive UUIDs locally —
/// the wheel is the source of truth. Renames in the operator's code
/// (function names, capability labels, mcp_name slugs) do NOT orphan
/// pricing-model rows, because the row's identity is its `tool_id`
/// (frozen at tool birth) and the canonical inventory's `tool_id`
/// matches what `@runtime.paid_tool(...)` registered.
///
/// Requires tollbooth-dpyc 0.38.0+ on the operator.
@MainActor
@Observable
final class ReconciliationViewModel {

    var mismatch: MCPService.ToolMismatch?
    var suggestedTools: [ToolPrice]?
    var isDetecting = false
    var isReconciling = false
    var error: String?
    var noMismatchMessage: String?

    private let mcpService = MCPService()

    // MARK: - Mismatch Detection

    func detectMismatch(
        endpointURL: URL,
        storedModel: PricingModelResponse,
        operatorSlug: String? = nil
    ) {
        isDetecting = true
        error = nil
        mismatch = nil
        suggestedTools = nil
        noMismatchMessage = nil

        Task {
            do {
                let result = try await mcpService.detectToolMismatch(
                    endpointURL: endpointURL,
                    storedModel: storedModel,
                    operatorSlug: operatorSlug
                )
                mismatch = result

                if !result.hasMismatch {
                    noMismatchMessage = "All good — live tools match the stored pricing model."
                }
            } catch {
                self.error = error.localizedDescription
            }
            isDetecting = false
        }
    }

    // MARK: - Deterministic Reconciliation

    /// Build the reconciled tool list from the UUID-joined mismatch.
    /// 1. Matched tools: keep the stored row, refresh `toolName`, `category`, and `intent`
    ///    from the canonical inventory if they've drifted (operator renamed something).
    /// 2. New canonical identities: add as TBD rows.
    /// 3. Stale stored rows: drop (omit from the suggested list).
    func reconcile(storedModel: PricingModelResponse) {
        guard let mismatch, mismatch.hasMismatch else { return }

        isReconciling = true
        suggestedTools = nil
        error = nil

        var reconciled: [ToolPrice] = []

        // 1. Matched: keep prices + multipliers, refresh display fields
        //    from canonical so renames propagate visually.
        for pair in mismatch.matchedPairs {
            let stored = pair.stored
            let canon = pair.canonical
            let nameChanged = stored.toolName != canon.mcpName
            let categoryChanged = stored.category != canon.category
            let intentChanged = stored.intent != canon.intent
            if nameChanged || categoryChanged || intentChanged {
                let toolId = stored.toolId
                let oldName = stored.toolName
                let newName = canon.mcpName
                let oldCategory = stored.category
                let newCategory = canon.category
                logger.info("Refreshing display for \(toolId): name '\(oldName)' → '\(newName)', category '\(oldCategory)' → '\(newCategory)'")
                reconciled.append(ToolPrice(
                    toolId: stored.toolId,
                    toolName: canon.mcpName,
                    priceSats: stored.priceSats,
                    priced: stored.priced,
                    priceType: stored.priceType,
                    priceFormula: stored.priceFormula,
                    category: canon.category,
                    intent: canon.intent,
                    minCost: stored.minCost,
                    maxCost: stored.maxCost,
                    multipliers: stored.multipliers
                ))
            } else {
                reconciled.append(stored)
            }
        }

        // 2. New: add at TBD, using canonical category and intent verbatim.
        for canon in mismatch.newIdentities {
            reconciled.append(ToolPrice(
                toolId: canon.toolId,
                toolName: canon.mcpName,
                priceSats: 0,
                priced: canon.category == "free",
                category: canon.category,
                intent: canon.intent
            ))
        }

        // 3. Stale: already omitted (not added to reconciled).

        let added = mismatch.newIdentities.count
        let removed = mismatch.staleTools.count
        logger.info(
            "Reconciled: \(added) added, \(removed) removed, \(reconciled.count) total"
        )

        suggestedTools = reconciled
        isReconciling = false
    }
}
