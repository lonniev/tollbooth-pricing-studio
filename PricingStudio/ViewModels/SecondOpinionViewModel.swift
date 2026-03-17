import Foundation
import OSLog

private let logger = Logger(subsystem: "com.tollbooth.dpyc.PricingStudio", category: "SecondOpinion")

/// GitHub raw URL for the community-managed pricing reviewer system prompt.
private let reviewerPromptURL = URL(string: "https://raw.githubusercontent.com/lonniev/dpyc-community/main/prompts/pricing-reviewer.md")!

/// Drives the Second Opinion review — sends campaign context to Grok (or Claude fallback)
/// and streams a structured critique.
///
/// Uses shared `ReviewSection` and `ReviewVerdict` types from `PeerReview.swift`.
/// Parsing is delegated to `ResponseParser.parseReviewSections(from:)`.
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

    /// The structured peer review, populated after a successful review.
    var peerReview: PeerReview?

    private var reviewerPrompt: String = ""

    // MARK: - Campaign Summary Assembly

    /// Build a single-message summary of the campaign for the reviewer.
    /// Delegates to CampaignSummaryBuilder.
    func buildCampaignSummary(
        messages: [AssistantMessage],
        progress: InterviewProgress,
        projections: CampaignProjections?,
        pipelineJSON: String?,
        operatorName: String?,
        campaignName: String?
    ) -> String {
        CampaignSummaryBuilder.buildForSecondOpinion(
            messages: messages,
            progress: progress,
            projections: projections,
            pipelineJSON: pipelineJSON,
            operatorName: operatorName,
            campaignName: campaignName
        )
    }

    // MARK: - Review Request

    /// Load the reviewer prompt and request a review from the best available provider.
    /// Collects the full response before displaying to the user.
    func requestReview(summary: String) {
        reviewText = ""
        sections = []
        hasSuggestedChanges = false
        suggestedChangesText = ""
        peerReview = nil
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

            // Post-process: parse into sections via ResponseParser
            reviewText = fullResponse
            sections = ResponseParser.parseReviewSections(from: fullResponse)

            let (hasSuggestions, suggestionsText) = ResponseParser.detectSuggestedChanges(from: fullResponse)
            hasSuggestedChanges = hasSuggestions
            suggestedChangesText = suggestionsText

            // Build the structured PeerReview value type
            let overallVerdict = sections.compactMap(\.verdict).last
            peerReview = PeerReview(
                providerName: providerName,
                rawResponse: fullResponse,
                sections: sections,
                verdict: overallVerdict,
                suggestedChanges: hasSuggestions ? suggestionsText : nil,
                reviewedAt: Date()
            )

            isStreaming = false
            logger.info("Second opinion complete (\(self.reviewText.count) chars)")
        }
    }

    /// Load an existing saved review without making an API call.
    func loadExistingReview(text: String) {
        reviewText = text
        sections = ResponseParser.parseReviewSections(from: text)
        let (hasSuggestions, suggestionsText) = ResponseParser.detectSuggestedChanges(from: text)
        hasSuggestedChanges = hasSuggestions
        suggestedChangesText = suggestionsText
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
