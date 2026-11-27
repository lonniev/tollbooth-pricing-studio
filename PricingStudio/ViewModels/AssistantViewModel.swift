import Foundation
import PricingStudioCore

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

    /// Role badge for the conversation header — current Owl slug.
    var roleDisplayLabel: String {
        ModelRoleSettings.displayLabel(for: .owl)
    }

    private let service = OpenRouterService()

    func sendUserMessage(_ text: String, context: AppContext) {
        let userMessage = AssistantMessage(role: .user, content: text)
        messages.append(userMessage)

        let model = ModelRoleSettings.slug(for: .owl)
        let assistantMessage = AssistantMessage(
            role: .assistant,
            content: "",
            isStreaming: true,
            modelSlug: model
        )
        messages.append(assistantMessage)
        isStreaming = true

        let apiMessages = messages.compactMap { msg -> [String: String]? in
            guard !msg.content.isEmpty else { return nil }
            return ["role": msg.role.rawValue, "content": msg.content]
        }

        let systemPrompt = buildSystemPrompt(context: context)
        let apiKey = KeychainService.loadOpenRouterAPIKey() ?? ""

        Task {
            let stream = service.sendMessage(
                messages: apiMessages,
                systemPrompt: systemPrompt,
                apiKey: apiKey,
                model: model,
                role: .owl
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

        You are the 🦉 Oracle of the DPYC ("Don't Pester Your Customer") network: \
        Bitcoin Lightning micropayments for MCP services, with Nostr npubs as identity.

        Answer every question about the DPYC from the Oracle's tools, called this turn. \
        Never state a fee, tax rate, credit expiry, version, wallet, URL or member from memory: \
        those change, and each Operator and Authority sets its own prices. \
        When a figure belongs to one Authority or Operator, say so and name the tool that \
        reports it (its check_price). If a tool fails, say the Oracle could not be reached \
        rather than answering from memory.

        Questions about the screen (the selected entity, its pricing model, balances) are \
        answered from the current state above.

        Be concise. Use short markdown headings and bullets where they help.
        """)

        return parts.joined(separator: "\n")
    }
}
