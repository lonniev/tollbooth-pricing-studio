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

        let stored = storedModel.tools ?? []
        let staleIds = Set(mismatch.staleTools.map(\.toolId))

        // Keep non-stale stored tools as-is
        var reconciled = stored.filter { !staleIds.contains($0.toolId) }

        // Add new tools at 0 sats (TBD)
        for tool in mismatch.newTools {
            let category = inferCategory(for: tool.name)
            reconciled.append(ToolPrice(
                toolId: ToolPrice.capabilityUUID(tool.name),
                toolName: tool.name,
                priceSats: 0,
                priced: category == "free",
                category: category,
                intent: tool.description ?? ""
            ))
        }

        let added = mismatch.newTools.count
        let removed = mismatch.staleTools.count
        logger.info("Reconciled: \(added) added, \(removed) removed, \(reconciled.count) total")

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
