import Foundation
import SwiftData
import OSLog

private let logger = Logger(subsystem: "com.tollbooth.dpyc.PricingStudio", category: "PricingConsultant")

/// GitHub raw URL for the community-managed pricing consultant system prompt.
private let communityPromptURL = URL(string: "https://raw.githubusercontent.com/lonniev/dpyc-community/main/prompts/pricing-consultant.md")!

/// Drives the AI Pricing Consultant conversation.
///
/// Fetches the system prompt from the dpyc-community GitHub repo,
/// allows local editing, and uses the Anthropic Messages API to
/// interview the operator and co-design a pricing campaign.
@MainActor
@Observable
final class PricingConsultantViewModel {

    var messages: [AssistantMessage] = []
    var isStreaming = false
    var interviewProgress: InterviewProgress = .default

    /// The system prompt — fetched from GitHub, editable locally.
    var systemPrompt: String = ""

    /// Whether the prompt was successfully loaded from the community repo.
    private(set) var promptSource: PromptSource = .notLoaded

    enum PromptSource: Sendable {
        case notLoaded
        case community
        case cached
        case fallback
        case edited
    }

    /// The currently loaded campaign, if any.
    var currentCampaign: Campaign?

    /// Stage being viewed (nil = current stage).
    var viewingStageNumber: Int?

    /// Revenue projections parsed from the latest synthesis response.
    var revenueProjections: CampaignProjections?

    /// Messages filtered by the currently viewed stage.
    var displayedMessages: [AssistantMessage] {
        let targetStage = viewingStageNumber ?? interviewProgress.stageNumber
        return messages.filter { msg in
            // Messages with no stage tag are shown in all stages
            guard let stage = msg.stageNumber else { return true }
            return stage == targetStage
        }
    }

    /// Non-nil when the latest assistant turn contains approved JSON.
    var extractedPipelineJSON: String? {
        guard let last = messages.last(where: { $0.role == .assistant && !$0.isStreaming }),
              !last.content.isEmpty else { return nil }
        return extractJSON(from: last.content)
    }

    private let service = AnthropicService()
    private var originalPrompt: String = ""

    // MARK: - Progress Parsing

    /// Regex to match `<!-- PROGRESS {...} -->` — uses dotMatchesLineSeparators
    /// so the JSON can span lines if Claude splits it.
    private static let progressPattern = try! NSRegularExpression(
        pattern: #"<!--\s*PROGRESS\s+(\{[\s\S]*?\})\s*-->"#,
        options: [.dotMatchesLineSeparators]
    )

    /// Strip the PROGRESS comment from displayed text and parse it.
    func parseAndStripProgress(from text: String) -> (stripped: String, progress: InterviewProgress?) {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = Self.progressPattern.firstMatch(in: text, range: range),
              let jsonRange = Range(match.range(at: 1), in: text) else {
            let suffix = text.suffix(200)
            logger.debug("PROGRESS parse: no match. Tail: \(suffix)")
            return (text, nil)
        }

        let jsonString = String(text[jsonRange])
        let stripped = Self.progressPattern.stringByReplacingMatches(
            in: text, range: range, withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = jsonString.data(using: .utf8) else {
            return (stripped, nil)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let progress = try? decoder.decode(InterviewProgress.self, from: data)
        if let progress {
            logger.debug("PROGRESS parsed: stage=\(progress.stage) number=\(progress.stageNumber)")
        } else {
            logger.debug("PROGRESS JSON found but decode failed: \(jsonString)")
        }
        return (stripped, progress)
    }

    // MARK: - Revenue Parsing

    /// Regex to match `<!-- REVENUE {...} -->`.
    private static let revenuePattern = try! NSRegularExpression(
        pattern: #"<!--\s*REVENUE\s+(\{[\s\S]*?\})\s*-->"#,
        options: [.dotMatchesLineSeparators]
    )

    /// Strip the REVENUE comment from displayed text and parse it.
    func parseAndStripRevenue(from text: String) -> (stripped: String, projections: CampaignProjections?) {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = Self.revenuePattern.firstMatch(in: text, range: range),
              let jsonRange = Range(match.range(at: 1), in: text) else {
            return (text, nil)
        }

        let jsonString = String(text[jsonRange])
        let stripped = Self.revenuePattern.stringByReplacingMatches(
            in: text, range: range, withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = jsonString.data(using: .utf8) else {
            return (stripped, nil)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let projections = try? decoder.decode(CampaignProjections.self, from: data)
        if let projections {
            logger.debug("REVENUE parsed: \(projections.projections.count) scenarios")
        } else {
            logger.debug("REVENUE JSON found but decode failed: \(jsonString)")
        }
        return (stripped, projections)
    }

    // MARK: - Prompt Loading

    func loadPrompt() async {
        do {
            let (data, response) = try await URLSession.shared.data(from: communityPromptURL)
            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200,
               let text = String(data: data, encoding: .utf8) {
                let extracted = extractPromptBody(from: text)
                systemPrompt = extracted
                originalPrompt = extracted
                promptSource = .community
                cachePrompt(extracted)
                logger.info("Loaded community prompt (\(extracted.count) chars)")
                return
            }
        } catch {
            logger.warning("Failed to fetch community prompt: \(error.localizedDescription)")
        }

        if let cached = loadCachedPrompt() {
            systemPrompt = cached
            originalPrompt = cached
            promptSource = .cached
            return
        }

        systemPrompt = Self.fallbackPrompt
        originalPrompt = Self.fallbackPrompt
        promptSource = .fallback
    }

    func markPromptEdited() {
        if systemPrompt != originalPrompt {
            promptSource = .edited
        }
    }

    func resetPrompt() {
        systemPrompt = originalPrompt
        promptSource = originalPrompt.isEmpty ? .notLoaded : .community
    }

    // MARK: - Conversation

    /// Start a new interview. Sends a brief user message; operator context
    /// is injected into the system prompt so Claude sees tools/pipeline
    /// without cluttering the visible chat.
    func startInterview(context: ConsultantContext) {
        messages.removeAll()
        currentCampaign = nil
        viewingStageNumber = nil
        revenueProjections = nil

        let opener = "Let's design a pricing campaign."
        let userMessage = AssistantMessage(role: .user, content: opener, stageNumber: 1)
        messages.append(userMessage)

        let placeholder = AssistantMessage(role: .assistant, content: "", isStreaming: true, stageNumber: 1)
        messages.append(placeholder)
        isStreaming = true

        let apiMessages: [[String: String]] = [
            ["role": "user", "content": opener]
        ]

        let fullPrompt = buildSystemPrompt(context: context)
        let apiKey = KeychainService.loadAnthropicAPIKey() ?? ""

        Task {
            let stream = await service.sendMessage(
                messages: apiMessages,
                systemPrompt: fullPrompt,
                apiKey: apiKey
            )

            for await token in stream {
                if let idx = self.messages.indices.last {
                    self.messages[idx].content += token
                }
            }

            if let idx = self.messages.indices.last {
                self.messages[idx].isStreaming = false
                var content = self.messages[idx].content

                // Parse and strip PROGRESS
                let (strippedProgress, progress) = self.parseAndStripProgress(from: content)
                content = strippedProgress
                if let progress { self.interviewProgress = progress }

                // Parse and strip REVENUE
                let (strippedRevenue, projections) = self.parseAndStripRevenue(from: content)
                content = strippedRevenue
                if let projections { self.revenueProjections = projections }

                self.messages[idx].content = content
                self.messages[idx].stageNumber = self.interviewProgress.stageNumber
            }
            self.isStreaming = false
            logger.info("Interview started (\(self.messages.count) messages)")
        }
    }

    func send(_ text: String, context: ConsultantContext) {
        let currentStage = interviewProgress.stageNumber
        let userMessage = AssistantMessage(role: .user, content: text, stageNumber: currentStage)
        messages.append(userMessage)

        let placeholder = AssistantMessage(role: .assistant, content: "", isStreaming: true, stageNumber: currentStage)
        messages.append(placeholder)
        isStreaming = true

        let apiMessages = messages.compactMap { msg -> [String: String]? in
            guard !msg.content.isEmpty else { return nil }
            return ["role": msg.role.rawValue, "content": msg.content]
        }

        let fullPrompt = buildSystemPrompt(context: context)
        let apiKey = KeychainService.loadAnthropicAPIKey() ?? ""

        Task {
            let stream = await service.sendMessage(
                messages: apiMessages,
                systemPrompt: fullPrompt,
                apiKey: apiKey
            )

            for await token in stream {
                if let idx = self.messages.indices.last {
                    self.messages[idx].content += token
                }
            }

            if let idx = self.messages.indices.last {
                self.messages[idx].isStreaming = false
                var content = self.messages[idx].content

                // Parse and strip PROGRESS
                let (strippedProgress, progress) = self.parseAndStripProgress(from: content)
                content = strippedProgress
                if let progress { self.interviewProgress = progress }

                // Parse and strip REVENUE
                let (strippedRevenue, projections) = self.parseAndStripRevenue(from: content)
                content = strippedRevenue
                if let projections { self.revenueProjections = projections }

                self.messages[idx].content = content
                self.messages[idx].stageNumber = self.interviewProgress.stageNumber
            }
            self.isStreaming = false
            // Return to current stage after sending
            self.viewingStageNumber = nil
            logger.info("Consultant turn complete (\(self.messages.count) messages)")
        }
    }

    /// Set viewing to a past or current stage.
    func revisitStage(_ stageNumber: Int) {
        viewingStageNumber = stageNumber
    }

    func clear() {
        messages.removeAll()
        currentCampaign = nil
        isStreaming = false
        interviewProgress = .default
        viewingStageNumber = nil
        revenueProjections = nil
    }

    // MARK: - Campaign Persistence

    /// Save the current conversation as a named campaign.
    func saveCampaign(name: String, operatorNpub: String, operatorDisplayName: String, context: ModelContext) {
        if let existing = currentCampaign {
            existing.name = name
            existing.messages = messages
            existing.interviewProgress = interviewProgress
            existing.revenueProjections = revenueProjections
        } else {
            let campaign = Campaign(
                name: name,
                operatorNpub: operatorNpub,
                operatorDisplayName: operatorDisplayName,
                messages: messages
            )
            campaign.interviewProgress = interviewProgress
            campaign.revenueProjections = revenueProjections
            context.insert(campaign)
            currentCampaign = campaign
        }
        try? context.save()
        logger.info("Saved campaign '\(name)' (\(self.messages.count) messages)")
    }

    /// Auto-save to the current campaign if one is loaded.
    func autoSave(context: ModelContext) {
        guard let campaign = currentCampaign else { return }
        campaign.messages = messages
        campaign.interviewProgress = interviewProgress
        campaign.revenueProjections = revenueProjections
        try? context.save()
    }

    /// Load a saved campaign's messages into the conversation.
    /// Automatically reshapes legacy messages that lack stage tags.
    func loadCampaign(_ campaign: Campaign) {
        messages = campaign.messages
        currentCampaign = campaign
        interviewProgress = campaign.interviewProgress ?? .default
        revenueProjections = campaign.revenueProjections
        isStreaming = false
        viewingStageNumber = nil

        // Reshape legacy campaigns that lack stage numbers
        let untaggedCount = messages.filter({ $0.stageNumber == nil }).count
        if untaggedCount > 0 && !messages.isEmpty {
            logger.info("Reshaping \(untaggedCount) untagged messages in '\(campaign.name)'")
            reshapeStages()
            // Persist the reshaped tags back
            campaign.messages = messages
        }

        logger.info("Loaded campaign '\(campaign.name)' (\(self.messages.count) messages)")
    }

    // MARK: - Legacy Reshape

    /// Re-tag messages that have nil stageNumber by parsing PROGRESS metadata
    /// or falling back to keyword heuristics.
    private func reshapeStages() {
        var currentStage = 1

        for i in messages.indices {
            if messages[i].stageNumber != nil {
                currentStage = messages[i].stageNumber!
                continue
            }

            // Try to recover stage from PROGRESS comment in assistant messages
            if messages[i].role == .assistant {
                let (stripped, progress) = parseAndStripProgress(from: messages[i].content)
                if let progress {
                    currentStage = progress.stageNumber
                    messages[i].content = stripped
                    messages[i].stageNumber = currentStage
                    if progress.stageNumber > interviewProgress.stageNumber {
                        interviewProgress = progress
                    }

                    // Also strip REVENUE if present
                    let (strippedRevenue, projections) = parseAndStripRevenue(from: messages[i].content)
                    if let projections {
                        messages[i].content = strippedRevenue
                        revenueProjections = projections
                    }
                    continue
                }
            }

            // Heuristic: classify by keyword presence in the message content
            let text = messages[i].content.lowercased()
            let detectedStage = classifyStageByKeywords(text)
            if let detected = detectedStage {
                currentStage = detected
            }
            messages[i].stageNumber = currentStage
        }
    }

    /// Simple keyword heuristic to guess which interview stage a message belongs to.
    private func classifyStageByKeywords(_ text: String) -> Int? {
        // Check from later stages first (more specific keywords)
        let stageKeywords: [(Int, [String])] = [
            (6, ["recommend", "final", "approve", "approved", "campaign draft", "here's the pricing", "bluf"]),
            (5, ["constraint", "free tier", "rate limit", "promotional", "fairness", "pipeline"]),
            (4, ["cost", "margin", "infrastructure", "serving cost", "overhead", "expense"]),
            (3, ["value", "willingness to pay", "wtp", "competitive", "worth", "perceive"]),
            (2, ["demand", "usage pattern", "market size", "adoption", "how many", "traffic"]),
            (1, ["tool", "inventory", "offer", "category", "what do you", "describe your"]),
        ]
        for (stage, keywords) in stageKeywords {
            if keywords.contains(where: { text.contains($0) }) {
                return stage
            }
        }
        return nil
    }

    /// Delete a campaign from the store.
    func deleteCampaign(_ campaign: Campaign, context: ModelContext) {
        if currentCampaign?.persistentModelID == campaign.persistentModelID {
            currentCampaign = nil
            messages.removeAll()
        }
        context.delete(campaign)
        try? context.save()
    }

    // MARK: - Fork / What-If

    /// Fork the conversation from a specific message index, replacing the user message
    /// at that index with new text and replaying from there.
    /// Returns the messages that were truncated (for undo/comparison).
    @discardableResult
    func forkFromMessage(at index: Int, newText: String, context: ConsultantContext) -> [AssistantMessage] {
        guard index < messages.count else { return [] }

        // Save truncated tail for potential undo
        let truncated = Array(messages.suffix(from: index))

        // Trim conversation to just before the fork point
        messages = Array(messages.prefix(index))

        // Send the new/edited message as a fresh turn
        send(newText, context: context)

        logger.info("Forked conversation at message \(index), truncated \(truncated.count) messages")
        return truncated
    }

    /// Create a what-if branch: forks and returns the branch without affecting
    /// the main conversation. Caller decides whether to persist.
    func whatIfBranch(at index: Int, newText: String, context: ConsultantContext) -> (branchMessages: [AssistantMessage], truncated: [AssistantMessage]) {
        // Snapshot current state
        let savedMessages = messages
        let savedProgress = interviewProgress
        let savedProjections = revenueProjections

        // Fork
        let truncated = forkFromMessage(at: index, newText: newText, context: context)
        let branchMessages = messages

        // Restore original state
        messages = savedMessages
        interviewProgress = savedProgress
        revenueProjections = savedProjections

        return (branchMessages, truncated)
    }

    // MARK: - Export

    /// Export the full interview transcript as Markdown.
    func exportTranscript() -> String {
        let dateStr = Date().formatted(.dateTime.year().month().day().hour().minute())
        let campaignName = currentCampaign?.name ?? "Untitled Campaign"
        let operatorName = currentCampaign?.operatorDisplayName ?? "Unknown"

        var lines: [String] = [
            "# Pricing Interview Transcript",
            "",
            "**Campaign:** \(campaignName)",
            "**Operator:** \(operatorName)",
            "**Date:** \(dateStr)",
            "",
            "---",
            "",
        ]

        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short

        for message in messages {
            let roleLabel = message.role == .user ? "Operator" : "Consultant"
            let time = formatter.string(from: message.timestamp)
            let stageLabel = message.stageNumber.map { "Stage \($0)" } ?? ""
            lines.append("### \(roleLabel) [\(time)] \(stageLabel)")
            lines.append("")
            lines.append(message.content)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - JSON Extraction

    private func extractJSON(from text: String) -> String? {
        if let fencedRange = text.range(of: #"```json\s*\n([\s\S]*?)\n```"#, options: .regularExpression) {
            let inner = text[fencedRange]
            let stripped = inner
                .replacingOccurrences(of: #"^```json\s*\n"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\n```$"#, with: "", options: .regularExpression)
            if isValidJSON(stripped) { return stripped }
        }

        guard let openIdx = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var closeIdx: String.Index?
        for i in text.indices[openIdx...] {
            if text[i] == "{" { depth += 1 }
            else if text[i] == "}" {
                depth -= 1
                if depth == 0 { closeIdx = i; break }
            }
        }
        guard let end = closeIdx else { return nil }
        let candidate = String(text[openIdx...end])
        return isValidJSON(candidate) ? candidate : nil
    }

    private func isValidJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    // MARK: - System Prompt Assembly

    private func buildSystemPrompt(context: ConsultantContext) -> String {
        var parts: [String] = [systemPrompt]

        // Inject operator context so Claude can greet naturally
        if let name = context.operatorName {
            parts.append("\nOperator name: \(name)")
        }
        if let tools = context.toolSummary, !tools.isEmpty {
            parts.append("\nOperator's current tools:\n\(tools)")
        }
        if let pipeline = context.currentPipeline, !pipeline.isEmpty {
            parts.append("\nCurrent pipeline:\n\(pipeline)")
        }

        // Instruction for natural greeting
        parts.append("""

        When starting a new conversation, greet the operator by name and \
        acknowledge the tools and pricing you can see in the context. \
        Do not repeat the raw tool list — instead summarize briefly \
        (e.g. "I see you have 12 tools across 3 categories") and \
        suggest which interview step to begin with.
        """)

        // Fallback formatting instructions (in case community prompt hasn't been updated)
        if !systemPrompt.contains("markdown table") {
            parts.append("""

            FORMATTING: Present all pricing data and constraint pipelines as markdown tables, \
            never as raw JSON blocks during the interview. Only output JSON at the very end \
            when the operator approves the final design.
            """)
        }

        if !systemPrompt.contains("BLUF") {
            parts.append("""

            BLUF: When you reach the Recommendation phase (stage 6), lead your response with a \
            one-paragraph Bottom Line Up Front summary stating the recommended philosophy, \
            expected monthly revenue (3 scenarios), and the most important constraint. \
            Follow with a revenue projection table and the full pricing/pipeline tables.
            """)
        }

        if !systemPrompt.contains("PROGRESS") {
            parts.append("""

            CRITICAL: At the end of EVERY response, you MUST emit a single hidden progress block.
            The JSON MUST be on a SINGLE LINE. Do NOT split it across lines.
            <!-- PROGRESS {"stage":"inventory","stage_number":1,"insights":{}} -->
            stage is one of: inventory, demand, value, cost, constraints, recommendation (numbered 1-6).
            Include insight fields as they become known: tools_identified (int), tools_categories (int), \
            demand_summary (string), value_summary (string), cost_summary (string), \
            constraints_considered (array of strings), campaign_draft ("pending"|"presented"|"approved"), \
            philosophy ("capitalist"|"balanced"|"charitable").
            This block is machine-parsed and stripped before display. It MUST appear at the END of every response.
            """)
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Prompt Parsing

    private func extractPromptBody(from markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")

        if let separatorIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            let bodyLines = lines.dropFirst(separatorIndex + 1)
            return bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let headingIndex = lines.firstIndex(where: { $0.hasPrefix("# ") }) {
            let bodyLines = lines.dropFirst(headingIndex + 1)
            return bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Local Cache

    private var cacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("com.tollbooth.dpyc.PricingStudio/pricing-consultant-prompt.md")
    }

    private func cachePrompt(_ text: String) {
        let dir = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: cacheURL, atomically: true, encoding: .utf8)
    }

    private func loadCachedPrompt() -> String? {
        try? String(contentsOf: cacheURL, encoding: .utf8)
    }

    // MARK: - Fallback Prompt

    private static let fallbackPrompt = """
    You are a revenue optimization consultant specializing in API and MCP tool \
    pricing. Your job is to interview the operator about their tools and co-design \
    a pricing campaign that maximizes revenue while matching expected demand patterns.

    ## Interview Structure

    Conduct a structured interview through six phases. Ask one focused question at a time. \
    Do not rush. Guide the operator deliberately through each phase before moving on.

    1. **Inventory** — Discover what tools the operator offers, their categories, and current pricing.
    2. **Demand** — Explore expected usage patterns, market size, user segments.
    3. **Value** — Assess willingness-to-pay, competitive positioning, perceived value.
    4. **Cost** — Understand serving costs, margin requirements, infrastructure overhead.
    5. **Constraints** — Design promotional mechanics, fairness rules, rate limits, free-tier policies.
    6. **Recommendation** — Present a complete pricing campaign draft for approval.

    ## Formatting Rules

    Present all pricing data as **markdown tables**, never as raw JSON. For example:

    | Tool | Category | Price (sats) | Intent |
    |------|----------|-------------|--------|
    | brain_search | query | 15 | Search across thoughts |

    When presenting constraint pipelines, use a table:

    | Step | Type | Parameters |
    |------|------|-----------|
    | 1 | free_tier | calls: 5, window: daily |

    ## BLUF (Bottom Line Up Front)

    When you reach the Recommendation phase, lead with a one-paragraph **BLUF** that states:
    - The recommended pricing philosophy (capitalist / balanced / charitable)
    - Expected monthly revenue under three scenarios (conservative, moderate, optimistic)
    - The single most important constraint in the pipeline and why

    Then present the full tool pricing table and constraint pipeline table.

    ## Revenue Projections

    In the Recommendation phase, include a revenue projection table:

    | Scenario | Monthly Users | Calls/User/Mo | Revenue (sats/mo) | Revenue (USD/mo) |
    |----------|--------------|---------------|-------------------|-----------------|
    | Conservative | ... | ... | ... | ... |
    | Moderate | ... | ... | ... | ... |
    | Optimistic | ... | ... | ... | ... |

    ## A/B/C Variant Proposals

    In the Recommendation phase, present **three distinct pricing variants** as labeled options:
    - **Variant A** — conservative/low-risk (lower prices, generous free tier)
    - **Variant B** — balanced/moderate (market-rate pricing, standard constraints)
    - **Variant C** — aggressive/high-revenue (premium pricing, tight constraints)

    Present each variant's tool pricing table and pipeline side by side. Include a \
    comparison table showing projected revenue for each variant across all three scenarios. \
    Ask the operator which variant they prefer, or whether they want a hybrid.

    ## Final JSON Output

    When the operator explicitly approves the design (or a specific variant), output a \
    fenced JSON block with "name", "tools" (array of tool_name/price_sats/category/intent), \
    and "pipeline" (array of type/params constraint steps). Do NOT output JSON until the \
    operator approves.
    """
}

// MARK: - Interview Progress

struct InterviewProgress: Codable, Equatable {
    var stage: String
    var stageNumber: Int
    var insights: Insights

    struct Insights: Codable, Equatable {
        var toolsIdentified: Int?
        var toolsCategories: Int?
        var demandSummary: String?
        var valueSummary: String?
        var costSummary: String?
        var constraintsConsidered: [String]?
        var campaignDraft: String?
        var philosophy: String?
    }

    static let `default` = InterviewProgress(
        stage: "inventory",
        stageNumber: 1,
        insights: Insights()
    )

    static let stageNames = ["inventory", "demand", "value", "cost", "constraints", "recommendation"]
    static let stageLabels = ["Inventory", "Demand", "Value", "Cost", "Constraints", "Recommendation"]
}

// MARK: - Context

struct ConsultantContext {
    var operatorName: String?
    var toolSummary: String?
    var currentPipeline: String?
}
