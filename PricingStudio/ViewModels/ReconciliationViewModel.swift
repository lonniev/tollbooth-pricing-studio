import Foundation
import OSLog

private let logger = Logger(subsystem: "com.tollbooth.dpyc.PricingStudio", category: "Reconciliation")

@MainActor
@Observable
final class ReconciliationViewModel {

    var mismatch: MCPService.ToolMismatch?
    var suggestedTools: [ToolPrice]?
    var reconciliationText: String = ""
    var isDetecting = false
    var isReconciling = false
    var error: String?
    var noMismatchMessage: String?
    var providerName: String = "Claude"

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
        reconciliationText = ""

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

    // MARK: - AI Reconciliation

    func requestReconciliation(storedModel: PricingModelResponse) {
        guard let mismatch, mismatch.hasMismatch else { return }

        isReconciling = true
        reconciliationText = ""
        suggestedTools = nil
        error = nil

        Task {
            let provider: any LLMProvider
            if let anthropicKey = KeychainService.loadAnthropicAPIKey(), !anthropicKey.isEmpty {
                provider = AnthropicProvider(apiKey: anthropicKey)
                providerName = "Claude"
            } else {
                error = "No Anthropic API key available. Add one in settings."
                isReconciling = false
                return
            }

            logger.info("Requesting reconciliation from \(self.providerName)")

            let userMessage = buildUserMessage(storedModel: storedModel, mismatch: mismatch)
            let messages: [[String: String]] = [
                ["role": "user", "content": userMessage]
            ]

            var fullResponse = ""
            let stream = provider.streamCompletion(
                messages: messages,
                systemPrompt: Self.systemPrompt,
                maxTokens: 4096
            )
            for await token in stream {
                fullResponse += token
                reconciliationText = fullResponse
            }

            if fullResponse.hasPrefix("[Error:") {
                error = fullResponse
                isReconciling = false
                return
            }

            reconciliationText = fullResponse
            logger.info("Raw LLM response (\(fullResponse.count) chars):\n\(fullResponse.prefix(2000))")
            suggestedTools = parseReconciledTools(from: fullResponse)

            if suggestedTools == nil {
                // Show the raw response in the error so the user can diagnose
                let preview = String(fullResponse.prefix(500))
                error = "Could not parse reconciled tools from AI response.\n\nRaw response:\n\(preview)"
                logger.error("Parse failed. Full response:\n\(fullResponse)")
            }

            isReconciling = false
            logger.info("Reconciliation complete (\(fullResponse.count) chars, \(self.suggestedTools?.count ?? 0) tools)")
        }
    }

    // MARK: - Response Parsing

    func parseReconciledTools(from text: String) -> [ToolPrice]? {
        // Find JSON object in the response
        guard let startIdx = text.firstIndex(of: "{"),
              let endIdx = text.lastIndex(of: "}") else { return nil }

        let jsonString = String(text[startIdx...endIdx])
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let toolDicts = obj["tools"] as? [[String: Any]] else { return nil }

        var tools: [ToolPrice] = []
        for dict in toolDicts {
            guard let name = dict["tool_name"] as? String,
                  let price = dict["price_sats"] as? Int,
                  let toolId = dict["tool_id"] as? String, !toolId.isEmpty else {
                logger.warning("Skipping tool without tool_id: \(dict["tool_name"] as? String ?? "?")")
                continue
            }
            let category = dict["category"] as? String ?? "read"
            let intent = dict["intent"] as? String ?? ""
            let priceType: PriceType
            if let typeStr = dict["price_type"] as? String {
                priceType = PriceType(rawValue: typeStr) ?? .flat
            } else {
                priceType = .flat
            }
            tools.append(ToolPrice(
                toolId: toolId,
                toolName: name,
                priceSats: price,
                priceType: priceType,
                category: category,
                intent: intent
            ))
        }
        return tools.isEmpty ? nil : tools
    }

    // MARK: - Prompt Construction

    private func buildUserMessage(storedModel: PricingModelResponse, mismatch: MCPService.ToolMismatch) -> String {
        let existingTools = (storedModel.tools ?? []).map { tool in
            "  {\"tool_id\": \"\(tool.toolId)\", \"tool_name\": \"\(tool.toolName)\", \"price_sats\": \(tool.priceSats), \"category\": \"\(tool.category)\", \"intent\": \"\(tool.intent)\"}"
        }.joined(separator: ",\n")

        let newToolsList = mismatch.newTools.map { tool in
            "  - \(tool.name): \(tool.description ?? "no description")"
        }.joined(separator: "\n")

        let staleToolsList = mismatch.staleTools.map { tool in
            "  - \(tool.toolName) (\(tool.category), \(tool.priceSats) sats)"
        }.joined(separator: "\n")

        // Price distribution summary
        let allTools = storedModel.tools ?? []
        let categories = Dictionary(grouping: allTools) { $0.category }
        let distribution = categories.map { "\($0.key): \($0.value.count) tools" }
            .sorted()
            .joined(separator: ", ")

        return """
        ## Existing Tool Prices
        [\(existingTools)]

        ## New Tools (need pricing)
        \(newToolsList)

        ## Stale Tools (to be removed)
        \(staleToolsList)

        ## Current Price Distribution
        \(distribution)

        Produce a reconciled pricing array that:
        1. Keeps ALL existing tool prices unchanged
        2. Adds appropriate prices for the new tools
        3. Does NOT include the stale tools
        """
    }

    // MARK: - System Prompt

    private static let systemPrompt = """
    You are a pricing reconciliation engine for a DPYC tollbooth operator. Produce a \
    reconciled tool pricing array given the operator's existing model, new tools, and \
    stale tools.

    Categories: free (0 sats), auth (0 sats), read (1 sat), write (5 sats), \
    heavy (10 sats), restricted (0 sats, operator-only).

    Infer category from tool name semantics and description. Match the operator's \
    existing pricing philosophy by analyzing their current price distribution.

    Return ONLY a JSON object: {"tools": [{"tool_id": "...", "tool_name": "...", \
    "price_sats": N, "price_type": "flat", "category": "...", "intent": "..."}]}
    Every tool MUST include its tool_id (UUID from the existing model or new tools list).
    Do NOT include stale tools. Do NOT modify existing tool prices.
    """
}
