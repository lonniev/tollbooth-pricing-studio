import Foundation
import OSLog

private let logger = Logger(subsystem: "com.tollbooth.dpyc.PricingStudio", category: "Reconciliation")

@MainActor
@Observable
final class ReconciliationViewModel {

    var mismatch: MCPService.ToolMismatch?
    var suggestedTools: [ToolPrice]?
    var isDetecting = false
    var isReconciling = false
    var error: String?
    var noMismatchMessage: String?

    /// How many stored rows the last reconcile() rewrote because their
    /// toolId UUID didn't match capabilityUUID(bareCapability(toolName)).
    /// Surfaced in the review UI so the operator knows the migration ran.
    private(set) var repairedOrphanCount: Int = 0

    private let mcpService = MCPService()

    /// Operator slug captured during detectMismatch() so reconcile()
    /// can strip it from MCP tool names before deriving capability UUIDs.
    /// Empty means "no slug" (treat names as bare capabilities).
    private var operatorSlug: String = ""

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
        // Capture for reconcile(): we strip this prefix from MCP tool
        // names to recover the bare capability the wheel's
        // capability_uuid() expects.
        self.operatorSlug = operatorSlug ?? ""

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

    /// Strip the operator slug prefix from an MCP tool name to recover
    /// the bare capability. The wheel computes `capability_uuid(...)`
    /// from the bare capability — never from the slug-prefixed protocol
    /// name. Reconcile rows whose toolId UUID was derived from the
    /// prefixed name will never match what the wheel looks up.
    func bareCapability(_ mcpName: String) -> String {
        guard !operatorSlug.isEmpty else { return mcpName }
        let prefix = "\(operatorSlug)_"
        guard mcpName.hasPrefix(prefix) else { return mcpName }
        return String(mcpName.dropFirst(prefix.count))
    }

    /// Canonical toolId for a given MCP-protocol tool name — what the
    /// wheel will look up at request time. Exposed for tests and the
    /// orphan-repair pass.
    func canonicalToolId(forMCPName mcpName: String) -> String {
        ToolPrice.capabilityUUID(bareCapability(mcpName))
    }

    /// Test seam — production sets `operatorSlug` via `detectMismatch`.
    /// Tests can't go through the live MCP path, so they call this.
    /// Marked clearly so it's never confused with app code.
    func _setOperatorSlug(_ slug: String) {
        self.operatorSlug = slug
    }

    // MARK: - Deterministic Reconciliation

    /// Build the reconciled tool list deterministically — no LLM needed.
    ///
    /// 1. Keep all matched tools with their existing prices
    /// 2. Add new tools at 0 sats with category inferred from the tool registry
    /// 3. Drop stale tools (they're simply omitted)
    func reconcile(storedModel: PricingModelResponse) {
        guard let mismatch, mismatch.hasMismatch else { return }

        isReconciling = true
        suggestedTools = nil
        error = nil
        repairedOrphanCount = 0

        let stored = storedModel.tools ?? []
        let staleIds = Set(mismatch.staleTools.map(\.toolId))

        // Keep non-stale stored tools, but ALSO repair any whose toolId
        // is an orphan from the prior Reconcile bug (UUID derived from
        // slug-prefixed name instead of bare capability). The repair
        // preserves the operator's price, priced flag, category,
        // multipliers — only the toolId UUID is rewritten.
        var reconciled: [ToolPrice] = []
        for tool in stored where !staleIds.contains(tool.toolId) {
            let canonical = canonicalToolId(forMCPName: tool.toolName)
            if tool.toolId != canonical {
                repairedOrphanCount += 1
                logger.info(
                    "Repairing orphan UUID for '\(tool.toolName)': \(tool.toolId) → \(canonical)"
                )
                reconciled.append(ToolPrice(
                    toolId: canonical,
                    toolName: tool.toolName,
                    priceSats: tool.priceSats,
                    priced: tool.priced,
                    priceType: tool.priceType,
                    priceFormula: tool.priceFormula,
                    category: tool.category,
                    intent: tool.intent,
                    minCost: tool.minCost,
                    maxCost: tool.maxCost,
                    multipliers: tool.multipliers
                ))
            } else {
                reconciled.append(tool)
            }
        }

        // Add new tools at 0 sats (TBD). Derive the toolId from the
        // BARE capability so the wheel's capability_uuid() lookup
        // succeeds; keep tool.name as the display label.
        for tool in mismatch.newTools {
            let category = inferCategory(for: tool.name)
            reconciled.append(ToolPrice(
                toolId: canonicalToolId(forMCPName: tool.name),
                toolName: tool.name,
                priceSats: 0,
                priced: category == "free",
                category: category,
                intent: tool.description ?? ""
            ))
        }

        let added = mismatch.newTools.count
        let removed = mismatch.staleTools.count
        let repaired = repairedOrphanCount
        logger.info(
            "Reconciled: \(added) added, \(removed) removed, \(repaired) orphan UUIDs repaired, \(reconciled.count) total"
        )

        suggestedTools = reconciled
        isReconciling = false
    }

    // MARK: - Category Inference

    /// Infer a default category from the tool name.
    /// Standard wheel tools have known categories; domain tools default to "read".
    private func inferCategory(for toolName: String) -> String {
        // Strip slug prefix to get the base name
        let base: String
        if let idx = toolName.firstIndex(of: "_") {
            base = String(toolName[toolName.index(after: idx)...])
        } else {
            base = toolName
        }

        // Known free tools (standard wheel tools)
        let freeTools: Set<String> = [
            "check_balance", "purchase_credits", "check_payment",
            "restore_credits", "account_statement", "service_status",
            "get_operator_onboarding_status", "get_patron_onboarding_status",
            "session_status", "request_credential_channel", "receive_credentials",
            "forget_credentials", "request_patron_credentials",
            "receive_patron_credentials", "check_authority_balance",
            "get_pricing_model", "check_price", "list_constraint_types",
            "get_notarization_proof", "list_notarizations",
            "request_npub_proof", "receive_npub_proof",
        ]

        // Known restricted tools
        let restrictedTools: Set<String> = [
            "set_pricing_model", "reset_pricing_model", "notarize_ledger",
        ]

        if freeTools.contains(base) { return "free" }
        if restrictedTools.contains(base) { return "restricted" }

        // account_statement_infographic is the one standard "read" tool
        if base == "account_statement_infographic" { return "read" }

        // Domain tools default to "read" (operator can adjust later)
        return "read"
    }
}
