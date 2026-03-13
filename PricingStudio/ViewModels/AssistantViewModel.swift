import Foundation

/// Context snapshot passed to the assistant for system prompt construction.
struct AppContext {
    var selectedEntityType: String?
    var selectedDisplayName: String?
    var selectedNpub: String?
    var toolCount: Int?
    var categoryCount: Int?
    var toolSummary: String?
    var balanceSats: Int?
    var operatorName: String?
    var conversationCount: Int?
}

@MainActor
@Observable
final class AssistantViewModel {

    var messages: [AssistantMessage] = []
    var isStreaming = false

    private let service = AnthropicService()

    func sendUserMessage(_ text: String, context: AppContext) {
        let userMessage = AssistantMessage(role: .user, content: text)
        messages.append(userMessage)

        let assistantMessage = AssistantMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(assistantMessage)
        isStreaming = true

        let apiMessages = messages.compactMap { msg -> [String: String]? in
            guard !msg.content.isEmpty else { return nil }
            return ["role": msg.role.rawValue, "content": msg.content]
        }

        let systemPrompt = buildSystemPrompt(context: context)
        let apiKey = KeychainService.loadAnthropicAPIKey() ?? ""

        Task {
            let stream = await service.sendMessage(
                messages: apiMessages,
                systemPrompt: systemPrompt,
                apiKey: apiKey
            )

            for await token in stream {
                if let idx = self.messages.indices.last {
                    self.messages[idx].content += token
                }
            }

            if let idx = self.messages.indices.last {
                self.messages[idx].isStreaming = false
            }
            self.isStreaming = false
        }
    }

    func clear() {
        messages.removeAll()
        isStreaming = false
    }

    // MARK: - System Prompt

    private func buildSystemPrompt(context: AppContext) -> String {
        var parts: [String] = [
            "You are an assistant for PricingStudio, an iPadOS app for managing DPYC Tollbooth actors."
        ]

        var stateLines: [String] = []

        if let entityType = context.selectedEntityType,
           let name = context.selectedDisplayName {
            var line = "Selected: \(entityType) \"\(name)\""
            if let npub = context.selectedNpub {
                line += " (npub: \(npub.prefix(20))...)"
            }
            stateLines.append(line)
        }

        if let toolCount = context.toolCount, let catCount = context.categoryCount {
            stateLines.append("Pricing model: \(toolCount) tools across \(catCount) categories")
            if let summary = context.toolSummary {
                stateLines.append(summary)
            }
        }

        if let balance = context.balanceSats, let opName = context.operatorName {
            stateLines.append("Balance: \(balance) sats on \(opName)")
        }

        if let convos = context.conversationCount, convos > 0 {
            stateLines.append("DM conversations: \(convos)")
        }

        if !stateLines.isEmpty {
            parts.append("\nCurrent state:\n- " + stateLines.joined(separator: "\n- "))
        }

        parts.append("""

        DPYC reference:
        - DPYC = "Don't Pester Your Customer" — API monetization via Bitcoin Lightning micropayments
        - Identity is a Nostr keypair (npub), not an email
        - Operators run MCP services, Authorities certify them
        - Pre-funded satoshi balances eliminate per-request payment ceremonies

        Answer questions about pricing, balances, tool usage, network membership, and the DPYC Tollbooth architecture. Be concise and specific.
        """)

        return parts.joined(separator: "\n")
    }
}
