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
    func loadCampaign(_ campaign: Campaign) {
        messages = campaign.messages
        currentCampaign = campaign
        interviewProgress = campaign.interviewProgress ?? .default
        revenueProjections = campaign.revenueProjections
        isStreaming = false
        viewingStageNumber = nil
        logger.info("Loaded campaign '\(campaign.name)' (\(self.messages.count) messages)")
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

        // Fallback PROGRESS instruction (in case community prompt hasn't been updated)
        if !systemPrompt.contains("PROGRESS") {
            parts.append("""

            CRITICAL: At the end of EVERY response, you MUST emit a single hidden progress block.
            The JSON MUST be on a SINGLE LINE. Do NOT split it across lines.
            <!-- PROGRESS {"stage":"inventory","stage_number":1,"insights":{}} -->
            stage is one of: inventory, demand, value, cost, constraints, synthesis (numbered 1-6).
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

    Conduct a structured interview: Inventory → Demand → Value → Cost → Constraints → \
    Synthesis → Refinement. Ask one focused question at a time. Do not rush to output. \
    When you have enough signal, present a draft and invite critique.

    When the operator approves your design, output ONLY a fenced JSON block with \
    "name", "tools" (array of tool_name/price_sats/category/intent), and "pipeline" \
    (array of type/params constraint steps).

    Do NOT output JSON until the operator explicitly approves the design.
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

    static let stageNames = ["inventory", "demand", "value", "cost", "constraints", "synthesis"]
    static let stageLabels = ["Inventory", "Demand", "Value", "Cost", "Constraints", "Synthesis"]
}

// MARK: - Context

struct ConsultantContext {
    var operatorName: String?
    var toolSummary: String?
    var currentPipeline: String?
}
