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
        // Strip [Oracle RAG] prefix for display — keep it in the API message for context
        let displayText = text.hasPrefix("[Oracle RAG] ")
            ? String(text.dropFirst("[Oracle RAG] ".count))
            : text
        let userMessage = AssistantMessage(role: .user, content: displayText)
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
            let stream = service.sendMessage(
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
        - Operators run MCP services monetized by Tollbooth fares (sat micropayments via Lightning)
        - Authorities certify Operators and collect an ad valorem certification fee on each purchase
        - Pre-funded satoshi balances eliminate per-request payment ceremonies
        - The Honor Chain: Prime Authority → Authorities → Operators → Patrons
        - Bitcoin Notarization: Merkle tree of all balances submitted to Bitcoin via OpenTimestamps
        - Secure Courier: Nostr DM-based credential delivery (never in chat)
        - Oracle: free community governance service (🦉 Owl of Athena) — not a tollbooth operator

        When a message begins with [Oracle RAG], the user asked via the 🦉 Oracle prompt panel.
        Answer as the Oracle of Athena — wise, authoritative, concise. Use markdown headings,
        bullet points, and paragraph breaks for readability. Draw on the DPYC ecosystem knowledge above.

        Key topics you can explain:
        - Membership tiers: Citizen, Advocate, Operator, Authority, First Curator
        - Economics: certification fees (2% ad valorem), Lightning invoices, tranche-based credit expiration (7-day TTL)
        - Getting started: generate Nostr keypair (Primal, nak), find a sponsoring Authority
        - Running an Operator: install tollbooth-dpyc, configure BTCPay, deploy on Horizon
        - Trust stack: LedgerCache → NeonVault → AuditedVault → Bitcoin Notarization (OTS)
        - Secure Courier: NIP-04/NIP-17 encrypted credential delivery via Nostr DMs
        - The Oracle itself: free community governance MCP, not tollbooth-monetized (bootstrap independence)

        If a question would benefit from live data (e.g., current member lookup, network advisory,
        live version info), mention that the 🦉 Oracle MCP can provide real-time answers and
        suggest the user check via the Oracle's tools in a connected MCP session.

        Answer questions about pricing, balances, tool usage, network membership, and the DPYC Tollbooth architecture. Be concise and specific.
        """)

        return parts.joined(separator: "\n")
    }
}
