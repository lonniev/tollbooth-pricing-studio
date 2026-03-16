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

    /// Parsed sections from the review for structured display.
    var sections: [ReviewSection] = []
    /// Whether the reviewer recommended changes (non-APPROVE verdict or has alternatives).
    var hasSuggestedChanges: Bool = false
    /// The alternative pricing suggestions section text, if any.
    var suggestedChangesText: String = ""

    private var reviewerPrompt: String = ""

    struct ReviewSection: Identifiable {
        let id = UUID()
        let title: String
        let icon: String
        let content: String
        let verdict: Verdict?

        enum Verdict {
            case approve, approveWithReservations, reworkRecommended, reject
        }
    }

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

    /// Load the reviewer prompt and request a review from the best available provider.
    /// Collects the full response before displaying to the user.
    func requestReview(summary: String) {
        reviewText = ""
        sections = []
        hasSuggestedChanges = false
        suggestedChangesText = ""
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

            // Collect full response (no live streaming to UI)
            var fullResponse = ""
            let stream = provider.streamCompletion(
                messages: messages,
                systemPrompt: prompt,
                maxTokens: 4096
            )
            for await token in stream {
                fullResponse += token
            }

            // Check for error in response
            if fullResponse.hasPrefix("[Error:") {
                error = fullResponse
                isStreaming = false
                return
            }

            // Post-process: parse into sections and present
            reviewText = fullResponse
            sections = parseSections(from: fullResponse)
            detectSuggestedChanges(from: fullResponse)

            isStreaming = false
            logger.info("Second opinion complete (\(self.reviewText.count) chars)")
        }
    }

    // MARK: - Response Parsing

    /// Parse the review into titled sections based on markdown headings.
    private func parseSections(from text: String) -> [ReviewSection] {
        let lines = text.components(separatedBy: "\n")
        var result: [ReviewSection] = []
        var currentTitle = ""
        var currentLines: [String] = []

        func flushSection() {
            let content = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !currentTitle.isEmpty, !content.isEmpty else { return }
            let (icon, verdict) = sectionMeta(for: currentTitle, content: content)
            result.append(ReviewSection(title: currentTitle, icon: icon, content: content, verdict: verdict))
        }

        for line in lines {
            // Match ## or **N.** section headers
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") || trimmed.hasPrefix("# ") {
                flushSection()
                currentTitle = trimmed
                    .replacingOccurrences(of: "## ", with: "")
                    .replacingOccurrences(of: "# ", with: "")
                    .trimmingCharacters(in: .init(charactersIn: "*#"))
                    .trimmingCharacters(in: .whitespaces)
                currentLines = []
            } else if let match = trimmed.range(of: #"^\d+\.\s+\*\*"#, options: .regularExpression) {
                flushSection()
                currentTitle = String(trimmed[match.upperBound...])
                    .replacingOccurrences(of: "**", with: "")
                    .trimmingCharacters(in: .init(charactersIn: " —-:"))
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }
        flushSection()

        return result
    }

    /// Map section titles to icons and detect verdict sections.
    private func sectionMeta(for title: String, content: String) -> (String, ReviewSection.Verdict?) {
        let lower = title.lowercased()
        if lower.contains("strength") {
            return ("checkmark.seal.fill", nil)
        } else if lower.contains("risk") || lower.contains("weakness") {
            return ("exclamationmark.triangle.fill", nil)
        } else if lower.contains("alternative") || lower.contains("suggestion") {
            return ("lightbulb.fill", nil)
        } else if lower.contains("revenue") || lower.contains("impact") {
            return ("chart.line.uptrend.xyaxis", nil)
        } else if lower.contains("verdict") || lower.contains("conclusion") {
            let verdictContent = content.uppercased()
            let verdict: ReviewSection.Verdict?
            if verdictContent.contains("REJECT") {
                verdict = .reject
            } else if verdictContent.contains("REWORK") {
                verdict = .reworkRecommended
            } else if verdictContent.contains("RESERVATIONS") {
                verdict = .approveWithReservations
            } else if verdictContent.contains("APPROVE") {
                verdict = .approve
            } else {
                verdict = nil
            }
            return ("gavel.fill", verdict)
        }
        return ("doc.text", nil)
    }

    /// Check if the reviewer suggested changes the operator might want to apply.
    private func detectSuggestedChanges(from text: String) {
        let upper = text.uppercased()
        // Has changes if verdict is not a clean APPROVE, or alternatives section exists
        let hasAlternatives = upper.contains("ALTERNATIVE") || upper.contains("SUGGESTION")
        let isCleanApprove = upper.contains("APPROVE") && !upper.contains("RESERVATION") && !upper.contains("REWORK") && !upper.contains("REJECT")

        hasSuggestedChanges = hasAlternatives && !isCleanApprove

        // Extract the alternatives section for potential campaign revision
        if hasSuggestedChanges {
            let lines = text.components(separatedBy: "\n")
            var capturing = false
            var captured: [String] = []
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().contains("alternative") || trimmed.lowercased().contains("suggestion") {
                    if trimmed.hasPrefix("#") || trimmed.range(of: #"^\d+\.\s+\*\*"#, options: .regularExpression) != nil {
                        capturing = true
                        continue
                    }
                }
                if capturing {
                    // Stop at next section header
                    if (trimmed.hasPrefix("#") || trimmed.range(of: #"^\d+\.\s+\*\*"#, options: .regularExpression) != nil) && !trimmed.lowercased().contains("alternative") {
                        break
                    }
                    captured.append(line)
                }
            }
            suggestedChangesText = captured.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
