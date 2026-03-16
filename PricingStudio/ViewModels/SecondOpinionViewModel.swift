import Foundation
import OSLog

private let logger = Logger(subsystem: "com.tollbooth.dpyc.PricingStudio", category: "SecondOpinion")

/// GitHub raw URL for the community-managed pricing reviewer system prompt.
private let reviewerPromptURL = URL(string: "https://raw.githubusercontent.com/lonniev/dpyc-community/main/prompts/pricing-reviewer.md")!

/// Drives the Second Opinion review — sends campaign context to Grok (or Claude fallback)
/// and streams a structured critique.
@MainActor
@Observable
final class SecondOpinionViewModel {

    var reviewText: String = ""
    var isStreaming = false
    var error: String?
    var providerName: String = "Grok"

    private var reviewerPrompt: String = ""

    // MARK: - Campaign Summary Assembly

    /// Build a single-message summary of the campaign for the reviewer.
    func buildCampaignSummary(
        messages: [AssistantMessage],
        progress: InterviewProgress,
        projections: CampaignProjections?,
        pipelineJSON: String?,
        operatorName: String?,
        campaignName: String?
    ) -> String {
        var parts: [String] = []

        // Identity
        let name = campaignName ?? "Untitled Campaign"
        let opName = operatorName ?? "Unknown Operator"
        parts.append("## Campaign: \(name)")
        parts.append("Operator: \(opName)")

        // Interview insights
        let insights = progress.insights
        parts.append("\n## Interview Insights")
        parts.append("Stage reached: \(progress.stage) (\(progress.stageNumber)/6)")
        if let tools = insights.toolsIdentified {
            parts.append("Tools identified: \(tools)")
        }
        if let cats = insights.toolsCategories {
            parts.append("Tool categories: \(cats)")
        }
        if let demand = insights.demandSummary {
            parts.append("Demand: \(demand)")
        }
        if let value = insights.valueSummary {
            parts.append("Value: \(value)")
        }
        if let cost = insights.costSummary {
            parts.append("Cost: \(cost)")
        }
        if let constraints = insights.constraintsConsidered, !constraints.isEmpty {
            parts.append("Constraints considered: \(constraints.joined(separator: ", "))")
        }
        if let philosophy = insights.philosophy {
            parts.append("Philosophy: \(philosophy)")
        }

        // Revenue projections
        if let projections {
            parts.append("\n## Revenue Projections")
            if let tam = projections.tam { parts.append("TAM: \(tam)") }
            if let sam = projections.sam { parts.append("SAM: \(sam)") }
            if let som = projections.som { parts.append("SOM: \(som)") }
            if let tc = projections.toolCount { parts.append("Tool count: \(tc)") }
            if let avg = projections.avgPriceSats { parts.append("Avg price: \(avg) sats") }
            for proj in projections.projections {
                parts.append("- \(proj.scenario): \(proj.monthlyUsers) users, \(proj.callsPerUserPerMonth) calls/user/mo, \(proj.revenueSats) sats/mo ($\(String(format: "%.2f", proj.revenueUsd))/mo)")
            }
        }

        // Final pricing JSON
        if let json = pipelineJSON {
            parts.append("\n## Pricing JSON")
            parts.append("```json")
            parts.append(json)
            parts.append("```")
        }

        // Condensed transcript (assistant messages only, truncated)
        let assistantMessages = messages
            .filter { $0.role == .assistant && !$0.content.isEmpty }
            .map { $0.content }
        let transcript = assistantMessages.joined(separator: "\n\n---\n\n")
        // Truncate to ~4000 chars to leave room for system prompt and response
        let truncated = transcript.count > 4000
            ? String(transcript.prefix(4000)) + "\n\n[...truncated...]"
            : transcript
        parts.append("\n## Consultant Reasoning (condensed)")
        parts.append(truncated)

        return parts.joined(separator: "\n")
    }

    // MARK: - Review Request

    /// Load the reviewer prompt and stream a review from the best available provider.
    func requestReview(summary: String) {
        reviewText = ""
        error = nil
        isStreaming = true

        Task {
            // Load reviewer prompt
            let prompt = await loadReviewerPrompt()

            // Pick provider: Grok if key exists, else Claude fallback
            let provider: any LLMProvider
            if let xaiKey = KeychainService.loadXAIAPIKey(), !xaiKey.isEmpty {
                provider = XAIProvider(apiKey: xaiKey)
                providerName = "Grok"
            } else if let anthropicKey = KeychainService.loadAnthropicAPIKey(), !anthropicKey.isEmpty {
                provider = AnthropicProvider(apiKey: anthropicKey)
                providerName = "Claude"
            } else {
                error = "No API key available. Add an xAI or Anthropic API key in settings."
                isStreaming = false
                return
            }

            logger.info("Requesting second opinion from \(self.providerName)")

            let messages: [[String: String]] = [
                ["role": "user", "content": summary]
            ]

            let stream = provider.streamCompletion(
                messages: messages,
                systemPrompt: prompt,
                maxTokens: 4096
            )

            for await token in stream {
                reviewText += token
            }

            // Check for error in response
            if reviewText.hasPrefix("[Error:") {
                error = reviewText
                reviewText = ""
            }

            isStreaming = false
            logger.info("Second opinion complete (\(self.reviewText.count) chars)")
        }
    }

    /// Load an existing saved review without making an API call.
    func loadExistingReview(text: String) {
        reviewText = text
        error = nil
        isStreaming = false
    }

    // MARK: - Prompt Loading

    private func loadReviewerPrompt() async -> String {
        // Try fetching from GitHub
        do {
            let (data, response) = try await URLSession.shared.data(from: reviewerPromptURL)
            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200,
               let text = String(data: data, encoding: .utf8) {
                let extracted = extractPromptBody(from: text)
                cacheReviewerPrompt(extracted)
                logger.info("Loaded reviewer prompt from community (\(extracted.count) chars)")
                return extracted
            }
        } catch {
            logger.warning("Failed to fetch reviewer prompt: \(error.localizedDescription)")
        }

        // Try cached
        if let cached = loadCachedReviewerPrompt() {
            logger.info("Using cached reviewer prompt")
            return cached
        }

        // Fallback
        logger.info("Using fallback reviewer prompt")
        return Self.fallbackPrompt
    }

    private func extractPromptBody(from markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        if let separatorIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
           separatorIndex > 0 {
            // Look for closing frontmatter separator
            let rest = lines.dropFirst(separatorIndex + 1)
            if let secondSep = rest.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                return lines.dropFirst(lines.distance(from: lines.startIndex, to: secondSep) + 1)
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let headingIndex = lines.firstIndex(where: { $0.hasPrefix("# ") }) {
            return lines.dropFirst(headingIndex).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Cache

    private var cacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("com.tollbooth.dpyc.PricingStudio/pricing-reviewer-prompt.md")
    }

    private func cacheReviewerPrompt(_ text: String) {
        let dir = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: cacheURL, atomically: true, encoding: .utf8)
    }

    private func loadCachedReviewerPrompt() -> String? {
        try? String(contentsOf: cacheURL, encoding: .utf8)
    }

    // MARK: - Fallback

    private static let fallbackPrompt = """
    You are a Devil's Advocate Pricing Analyst reviewing a pricing campaign for a \
    DPYC (Don't Price Your Curiosity) operator.

    ## DPYC Economic Context

    DPYC is NOT a conventional SaaS or enterprise software ecosystem. Before critiquing, \
    understand the DPYC worldview:

    - **No KYC.** Identity is Nostr-based (npub/nsec). No email, no accounts, no PII.
    - **Sat-denominated micropayments.** Prices are in Bitcoin satoshis, not USD. \
      Typical tool calls cost 1–100 sats each. Think vending machine, not subscription.
    - **Constraint pipelines, not paywalls.** Operators compose fairness rules \
      (free tiers, rate limits, time windows) as pipeline steps — not binary access gates.
    - **Austrian pricing philosophy.** Value is subjective; price discovery happens \
      between willing operator and willing patron. No central price authority.
    - **Tollbooth model.** Operators run MCP tool servers. Patrons pay per-call via \
      Lightning/sats. The tollbooth middleware handles metering, not the tools themselves.

    For authoritative details on the DPYC economic model, consult:
    - DPYC Oracle MCP tools: `about`, `economic_model`, `get_rulebook`
    - Community repo: https://github.com/lonniev/dpyc-community

    ## Review Instructions

    Critique the campaign **within the DPYC frame**, not from a SaaS/enterprise lens. \
    Do not recommend KYC, subscription tiers, or annual contracts. Do not assume USD \
    pricing norms. Focus on sat-denominated unit economics.

    Produce exactly these sections:

    1. **Strengths** — what the campaign gets right within DPYC economics
    2. **Risks and Weaknesses** — elasticity, constraint gaming, demand errors, \
       sat/USD exchange volatility, free-tier abuse
    3. **Alternative Pricing Suggestions** — concrete alternatives with sat numbers
    4. **Revenue Impact Assessment** — re-estimated 3 scenarios under your suggestions
    5. **Final Verdict** — APPROVE / APPROVE WITH RESERVATIONS / REWORK RECOMMENDED / REJECT

    Be direct. Use numbers. No hedging. Keep under 1500 words.
    """
}
