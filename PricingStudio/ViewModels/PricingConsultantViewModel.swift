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

    /// Per-stage isolated message arrays. Key = stage number (1-6).
    var stageMessages: [Int: [AssistantMessage]] = [:]

    /// Flat accessor retained for backward compatibility — returns all messages in stage order.
    var messages: [AssistantMessage] {
        get { allMessages }
        set {
            // Group by stageNumber for backward compat with callers that set .messages directly
            var grouped: [Int: [AssistantMessage]] = [:]
            for msg in newValue {
                let stage = msg.stageNumber ?? 1
                grouped[stage, default: []].append(msg)
            }
            stageMessages = grouped
        }
    }

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

    /// Messages for the currently viewed stage's isolated conversation.
    /// Stage 6 (Recommendation) buffers the streaming assistant response —
    /// it only appears once streaming is complete, so the user sees a clean
    /// rendered result instead of messy incremental markdown.
    var displayedMessages: [AssistantMessage] {
        let targetStage = viewingStageNumber ?? interviewProgress.stageNumber
        var msgs = stageMessages[targetStage] ?? []
        // Buffer stage 6 assistant messages while streaming
        if targetStage == 6 {
            msgs = msgs.filter { !($0.role == .assistant && $0.isStreaming) }
        }
        return msgs
    }

    /// All messages across all stages, in stage order.
    var allMessages: [AssistantMessage] {
        (1...6).flatMap { stageMessages[$0] ?? [] }
    }

    /// Direct accessor for a specific stage's messages.
    func messages(for stage: Int) -> [AssistantMessage] {
        stageMessages[stage] ?? []
    }

    /// Cached pipeline JSON extracted before display cleanup.
    var extractedPipelineJSON: String?

    /// Structured interview analysis — stage classifications and insights.
    var analysis: InterviewAnalysis = InterviewAnalysis()

    /// Structured pricing proposal — pipeline, tool prices, projections.
    var proposal: PricingProposal = PricingProposal()

    private let service = AnthropicService()
    private var originalPrompt: String = ""

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
        stageMessages = [:]
        currentCampaign = nil
        viewingStageNumber = nil
        revenueProjections = nil
        interviewProgress = .default

        let opener = "Let's design a pricing campaign."
        let userMessage = AssistantMessage(role: .user, content: opener, stageNumber: 1)
        stageMessages[1, default: []].append(userMessage)

        let placeholder = AssistantMessage(role: .assistant, content: "", isStreaming: true, stageNumber: 1)
        stageMessages[1, default: []].append(placeholder)
        isStreaming = true

        let apiMessages: [[String: String]] = [
            ["role": "user", "content": opener]
        ]

        let fullPrompt = buildStageSystemPrompt(stage: 1, context: context)
        let apiKey = KeychainService.loadAnthropicAPIKey() ?? ""

        Task {
            let stream = service.sendMessage(
                messages: apiMessages,
                systemPrompt: fullPrompt,
                apiKey: apiKey
            )

            for await token in stream {
                if var msgs = self.stageMessages[1], let idx = msgs.indices.last {
                    msgs[idx].content += token
                    self.stageMessages[1] = msgs
                }
            }

            if var msgs = self.stageMessages[1], let idx = msgs.indices.last {
                msgs[idx].isStreaming = false
                self.stageMessages[1] = msgs
                self.processResponse(stage: 1, at: idx)
            }
            self.isStreaming = false
            logger.info("Interview started (\(self.allMessages.count) messages)")
        }
    }

    func send(_ text: String, context: ConsultantContext) {
        let targetStage = viewingStageNumber ?? interviewProgress.stageNumber
        let userMessage = AssistantMessage(role: .user, content: text, stageNumber: targetStage)
        stageMessages[targetStage, default: []].append(userMessage)

        let placeholder = AssistantMessage(role: .assistant, content: "", isStreaming: true, stageNumber: targetStage)
        stageMessages[targetStage, default: []].append(placeholder)
        isStreaming = true

        // Send ONLY this stage's messages to the API
        let stageMsgs = stageMessages[targetStage] ?? []
        let apiMessages = stageMsgs.compactMap { msg -> [String: String]? in
            guard !msg.content.isEmpty else { return nil }
            return ["role": msg.role.rawValue, "content": msg.content]
        }

        let fullPrompt = buildStageSystemPrompt(stage: targetStage, context: context)
        let apiKey = KeychainService.loadAnthropicAPIKey() ?? ""

        Task {
            let stream = service.sendMessage(
                messages: apiMessages,
                systemPrompt: fullPrompt,
                apiKey: apiKey
            )

            for await token in stream {
                if var msgs = self.stageMessages[targetStage], let idx = msgs.indices.last {
                    msgs[idx].content += token
                    self.stageMessages[targetStage] = msgs
                }
            }

            if var msgs = self.stageMessages[targetStage], let idx = msgs.indices.last {
                msgs[idx].isStreaming = false
                self.stageMessages[targetStage] = msgs
                self.processResponse(stage: targetStage, at: idx)
            }
            self.isStreaming = false
            // Return to current stage after sending
            self.viewingStageNumber = nil
            logger.info("Consultant turn complete (\(self.allMessages.count) messages)")
        }
    }

    /// Post-stream processing: extract structured data via ResponseParser,
    /// then clean the message for display.
    private func processResponse(stage: Int, at idx: Int) {
        guard var msgs = stageMessages[stage], idx < msgs.count else { return }
        var content = msgs[idx].content

        // Parse and strip PROGRESS
        let (strippedProgress, progress) = ResponseParser.extractProgress(from: content)
        content = strippedProgress
        if let progress {
            // Stage transitions: when PROGRESS indicates N+1, the response stays in stage N.
            // Next user message will start N+1.
            if progress.stageNumber > interviewProgress.stageNumber {
                interviewProgress = progress
            }
            analysis.insights = progress.insights
        }

        // Parse and strip REVENUE
        let (strippedRevenue, projections) = ResponseParser.extractRevenue(from: content)
        content = strippedRevenue
        if let projections {
            revenueProjections = projections
            proposal.projections = projections
            proposal.generatedAt = Date()
        }

        // Extract pipeline JSON before cleaning for display
        if let json = ResponseParser.extractCampaignJSON(from: content) {
            extractedPipelineJSON = json
            proposal.pipelineJSON = json
        }

        // Clean remaining machine artifacts for display
        content = ResponseParser.cleanForDisplay(content)

        msgs[idx].content = content
        msgs[idx].stageNumber = stage
        stageMessages[stage] = msgs
    }

    /// Set viewing to a past or current stage.
    func revisitStage(_ stageNumber: Int) {
        viewingStageNumber = stageNumber
    }

    func clear() {
        stageMessages = [:]
        currentCampaign = nil
        isStreaming = false
        interviewProgress = .default
        viewingStageNumber = nil
        revenueProjections = nil
        extractedPipelineJSON = nil
        analysis = InterviewAnalysis()
        proposal = PricingProposal()
    }

    // MARK: - Campaign Persistence

    /// Save the current conversation as a named campaign.
    func saveCampaign(name: String, operatorNpub: String, operatorDisplayName: String, context: ModelContext) {
        if let existing = currentCampaign {
            existing.name = name
            existing.stageMessages = stageMessages
            existing.messages = allMessages  // backward compat
            existing.interviewProgress = interviewProgress
            existing.revenueProjections = revenueProjections
            existing.analysis = analysis
            existing.proposal = proposal
        } else {
            let campaign = Campaign(
                name: name,
                operatorNpub: operatorNpub,
                operatorDisplayName: operatorDisplayName,
                messages: allMessages
            )
            campaign.stageMessages = stageMessages
            campaign.interviewProgress = interviewProgress
            campaign.revenueProjections = revenueProjections
            campaign.analysis = analysis
            campaign.proposal = proposal
            context.insert(campaign)
            currentCampaign = campaign
        }
        try? context.save()
        logger.info("Saved campaign '\(name)' (\(self.allMessages.count) messages)")
    }

    /// Auto-save to the current campaign if one is loaded.
    func autoSave(context: ModelContext) {
        guard let campaign = currentCampaign else { return }
        campaign.stageMessages = stageMessages
        campaign.messages = allMessages  // backward compat
        campaign.interviewProgress = interviewProgress
        campaign.revenueProjections = revenueProjections
        campaign.analysis = analysis
        campaign.proposal = proposal
        try? context.save()
    }

    /// Load a saved campaign's messages into the conversation.
    /// Automatically migrates legacy flat messages to per-stage storage.
    func loadCampaign(_ campaign: Campaign) {
        currentCampaign = campaign
        interviewProgress = campaign.interviewProgress ?? .default
        revenueProjections = campaign.revenueProjections
        isStreaming = false
        viewingStageNumber = nil

        // Hydrate value types from campaign persistence
        analysis = campaign.analysis ?? InterviewAnalysis()
        proposal = campaign.proposal ?? PricingProposal()

        // Load from per-stage storage if available, otherwise migrate
        let loaded = campaign.stageMessages
        if !loaded.isEmpty {
            stageMessages = loaded
        } else {
            // Legacy campaign — migrate flat messages to per-stage
            var flat = campaign.messages

            // Clean machine artifacts from legacy messages and extract cached JSON
            for i in flat.indices where flat[i].role == .assistant {
                if let json = ResponseParser.extractCampaignJSON(from: flat[i].content) {
                    extractedPipelineJSON = json
                    proposal.pipelineJSON = json
                }
                flat[i].content = ResponseParser.cleanForDisplay(flat[i].content)
            }

            // Reshape legacy campaigns that lack stage numbers
            let untaggedCount = flat.filter({ $0.stageNumber == nil }).count
            if untaggedCount > 0 && !flat.isEmpty {
                logger.info("Reshaping \(untaggedCount) untagged messages in '\(campaign.name)'")
                reshapeStagesInPlace(&flat)
            }

            // Group into stages
            var grouped: [Int: [AssistantMessage]] = [:]
            for msg in flat {
                let stage = msg.stageNumber ?? 1
                grouped[stage, default: []].append(msg)
            }
            stageMessages = grouped

            // Persist migrated result
            campaign.stageMessages = stageMessages
            campaign.messages = allMessages
        }

        // Extract pipeline JSON from loaded messages
        for msg in allMessages where msg.role == .assistant {
            if let json = ResponseParser.extractCampaignJSON(from: msg.content) {
                extractedPipelineJSON = json
                proposal.pipelineJSON = json
            }
        }

        logger.info("Loaded campaign '\(campaign.name)' (\(self.allMessages.count) messages)")
    }

    // MARK: - Legacy Reshape

    /// Force re-reshape using keyword heuristics (offline fallback).
    func forceReshape(context: ModelContext? = nil) {
        var flat = allMessages
        for i in flat.indices {
            flat[i].stageNumber = nil
        }
        interviewProgress = .default
        reshapeStagesInPlace(&flat)

        // Regroup into stages
        var grouped: [Int: [AssistantMessage]] = [:]
        for msg in flat {
            let stage = msg.stageNumber ?? 1
            grouped[stage, default: []].append(msg)
        }
        stageMessages = grouped
        persistReshape(context: context)
        logger.info("Force-reshaped \(self.allMessages.count) messages (keyword heuristics)")
    }

    /// AI-powered reshape: sends the transcript to the LLM to classify each
    /// message into the correct interview stage. Results are stored in
    /// `pendingReshape` for preview before the user confirms overwrite.
    var isReshaping = false
    var reshapeError: String?
    var pendingReshape: [Int]?   // stage number per message index, awaiting confirmation

    func aiReshape() {
        guard !messages.isEmpty else { return }
        isReshaping = true
        reshapeError = nil
        pendingReshape = nil

        Task {
            guard let anthropicKey = KeychainService.loadAnthropicAPIKey(), !anthropicKey.isEmpty else {
                reshapeError = "No Anthropic API key available. Add one in settings."
                isReshaping = false
                return
            }
            let provider: any LLMProvider = AnthropicProvider(apiKey: anthropicKey)

            let result = await StageClassifier.classifyViaAI(messages: messages, provider: provider)
            switch result {
            case .success(let stages):
                pendingReshape = stages
                logger.info("AI reshape complete: \(stages)")
            case .failure(.parseFailed(let response)):
                reshapeError = "AI returned unexpected format. Got \(response)"
                logger.warning("AI reshape parse failed: \(response)")
            }
            isReshaping = false
        }
    }

    /// Accept the pending AI reshape and overwrite message stage tags.
    func acceptReshape(context: ModelContext? = nil) {
        var flat = allMessages
        guard let stages = pendingReshape, stages.count == flat.count else { return }
        for i in flat.indices {
            flat[i].stageNumber = stages[i]
        }
        // Update interview progress to the highest stage reached
        if let maxStage = stages.max() {
            let stageNames = ["", "inventory", "demand", "value", "cost", "constraints", "recommendation"]
            interviewProgress = InterviewProgress(
                stage: stageNames[maxStage],
                stageNumber: maxStage,
                insights: interviewProgress.insights
            )
        }
        // Regroup into stages
        var grouped: [Int: [AssistantMessage]] = [:]
        for msg in flat {
            let stage = msg.stageNumber ?? 1
            grouped[stage, default: []].append(msg)
        }
        stageMessages = grouped
        pendingReshape = nil
        persistReshape(context: context)
        logger.info("Accepted AI reshape")
    }

    /// Discard the pending reshape preview.
    func discardReshape() {
        pendingReshape = nil
    }

    private func persistReshape(context: ModelContext? = nil) {
        if let campaign = currentCampaign {
            campaign.stageMessages = stageMessages
            campaign.messages = allMessages
            campaign.interviewProgress = interviewProgress
            try? context?.save()
        }
    }

    /// Re-tag messages in-place by parsing PROGRESS metadata or keyword heuristics.
    /// Stage progression is **monotonically increasing**.
    private func reshapeStagesInPlace(_ msgs: inout [AssistantMessage]) {
        var currentStage = 1

        for i in msgs.indices {
            if msgs[i].stageNumber != nil {
                currentStage = max(currentStage, msgs[i].stageNumber!)
                continue
            }

            // Try to recover stage from PROGRESS comment in assistant messages
            if msgs[i].role == .assistant {
                let (stripped, progress) = ResponseParser.extractProgress(from: msgs[i].content)
                if let progress {
                    currentStage = max(currentStage, progress.stageNumber)
                    msgs[i].content = stripped
                    msgs[i].stageNumber = currentStage
                    if progress.stageNumber > interviewProgress.stageNumber {
                        interviewProgress = progress
                    }

                    // Also strip REVENUE if present
                    let (strippedRevenue, projections) = ResponseParser.extractRevenue(from: msgs[i].content)
                    if let projections {
                        msgs[i].content = strippedRevenue
                        revenueProjections = projections
                        proposal.projections = projections
                    }
                    continue
                }
            }

            // Heuristic: classify by transition-signaling phrases in the content.
            let text = msgs[i].content.lowercased()
            if let detected = StageClassifier.detectStageByKeywords(text), detected > currentStage {
                currentStage = detected
            }
            msgs[i].stageNumber = currentStage
        }
    }

    /// Delete a campaign from the store.
    func deleteCampaign(_ campaign: Campaign, context: ModelContext) {
        if currentCampaign?.persistentModelID == campaign.persistentModelID {
            currentCampaign = nil
            stageMessages = [:]
        }
        context.delete(campaign)
        try? context.save()
    }

    // MARK: - Fork / What-If

    /// Fork the conversation from a specific message index (across allMessages),
    /// replacing the user message at that index with new text and replaying from there.
    /// Returns the messages that were truncated (for undo/comparison).
    @discardableResult
    func forkFromMessage(at index: Int, newText: String, context: ConsultantContext) -> [AssistantMessage] {
        let flat = allMessages
        guard index < flat.count else { return [] }

        // Save truncated tail for potential undo
        let truncated = Array(flat.suffix(from: index))
        let kept = Array(flat.prefix(index))

        // Determine what stage the fork point belongs to
        let forkStage = flat[index].stageNumber ?? interviewProgress.stageNumber

        // Rebuild stageMessages from kept messages
        var grouped: [Int: [AssistantMessage]] = [:]
        for msg in kept {
            let stage = msg.stageNumber ?? 1
            grouped[stage, default: []].append(msg)
        }
        stageMessages = grouped

        // Send the new/edited message as a fresh turn in the fork stage
        viewingStageNumber = forkStage
        send(newText, context: context)

        logger.info("Forked conversation at message \(index), truncated \(truncated.count) messages")
        return truncated
    }

    /// Create a what-if branch: forks and returns the branch without affecting
    /// the main conversation. Caller decides whether to persist.
    func whatIfBranch(at index: Int, newText: String, context: ConsultantContext) -> (branchMessages: [AssistantMessage], truncated: [AssistantMessage]) {
        // Snapshot current state
        let savedStageMessages = stageMessages
        let savedProgress = interviewProgress
        let savedProjections = revenueProjections

        // Fork
        let truncated = forkFromMessage(at: index, newText: newText, context: context)
        let branchMessages = allMessages

        // Restore original state
        stageMessages = savedStageMessages
        interviewProgress = savedProgress
        revenueProjections = savedProjections

        return (branchMessages, truncated)
    }

    // MARK: - Export

    /// Export the full interview transcript as Markdown, organized by stage.
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

        for stage in 1...6 {
            let msgs = stageMessages[stage] ?? []
            guard !msgs.isEmpty else { continue }

            let stageLabel = stage <= InterviewProgress.stageLabels.count
                ? InterviewProgress.stageLabels[stage - 1]
                : "Stage \(stage)"
            lines.append("## Phase \(stage): \(stageLabel)")
            lines.append("")

            for message in msgs {
                let roleLabel = message.role == .user ? "Operator" : "Consultant"
                let time = formatter.string(from: message.timestamp)
                lines.append("### \(roleLabel) [\(time)]")
                lines.append("")
                lines.append(message.content)
                lines.append("")
            }

            lines.append("---")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // Content cleanup and JSON extraction delegated to ResponseParser

    // MARK: - System Prompt Assembly

    /// Build a stage-specific system prompt that includes prior-stage context.
    private func buildStageSystemPrompt(stage: Int, context: ConsultantContext) -> String {
        var parts: [String] = [buildBaseSystemPrompt(context: context)]

        // Stage-specific focus instruction
        let stageFocus: [Int: String] = [
            1: "You are in the INVENTORY phase. Focus exclusively on discovering the operator's tools, categories, and current pricing. Do not discuss demand, value, costs, or constraints yet.",
            2: "You are in the DEMAND phase. Focus exclusively on exploring expected usage patterns, market size, and user segments. Build on the inventory findings.",
            3: "You are in the VALUE phase. Focus exclusively on assessing willingness-to-pay, competitive positioning, and perceived value.",
            4: "You are in the COST phase. Focus exclusively on understanding serving costs, margin requirements, and infrastructure overhead.",
            5: "You are in the CONSTRAINTS phase. Focus exclusively on designing promotional mechanics, fairness rules, rate limits, and free-tier policies.",
            6: "You are in the RECOMMENDATION phase. Synthesize all prior findings and present a complete pricing campaign draft with BLUF, revenue projections, and A/B/C variants.",
        ]

        if let focus = stageFocus[stage] {
            parts.append("\n## Current Phase\n\(focus)")
        }

        // For stages 2+, synthesize prior-stage context from insights
        if stage >= 2 {
            var priorContext: [String] = ["\n## Context from Prior Phases"]
            let insights = interviewProgress.insights

            if let tools = insights.toolsIdentified {
                priorContext.append("- Inventory: \(tools) tools identified" +
                    (insights.toolsCategories.map { " across \($0) categories" } ?? ""))
            }
            if stage >= 3, let demand = insights.demandSummary {
                priorContext.append("- Demand: \(demand)")
            }
            if stage >= 4, let value = insights.valueSummary {
                priorContext.append("- Value: \(value)")
            }
            if stage >= 5, let cost = insights.costSummary {
                priorContext.append("- Cost: \(cost)")
            }
            if stage >= 6, let constraints = insights.constraintsConsidered, !constraints.isEmpty {
                priorContext.append("- Constraints considered: \(constraints.joined(separator: ", "))")
            }
            if let philosophy = insights.philosophy {
                priorContext.append("- Pricing philosophy: \(philosophy)")
            }

            if priorContext.count > 1 {
                parts.append(priorContext.joined(separator: "\n"))
            }
        }

        return parts.joined(separator: "\n")
    }

    private func buildBaseSystemPrompt(context: ConsultantContext) -> String {
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

            FORMATTING: Present all pricing data and constraint pipelines as human-readable \
            markdown tables, NEVER as raw JSON code fences. The user sees rendered markdown — \
            JSON blocks look ugly and are not actionable to humans.

            When the operator approves the final design, emit the campaign JSON inside a hidden \
            HTML comment: <!-- CAMPAIGN_JSON {...} -->
            This is machine-parsed by the app and never shown to the user. Keep your visible \
            response as clean markdown tables and prose only.
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
