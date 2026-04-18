import Foundation
import MCP
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

    /// Stage being viewed. Always set — each stage is a separate chapter.
    /// Defaults to 1 (Inventory). Navigation between stages is explicit.
    var viewingStageNumber: Int? = 1

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
        viewingStageNumber = 1
        revenueProjections = nil
        interviewProgress = .default

        // Configure operator tool access for the AI advisor
        configureOperatorTools(context: context)

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
        // Ensure operator tools are configured (may be first call after loadCampaign)
        if AnthropicService.operatorTools.isEmpty {
            configureOperatorTools(context: context)
        }
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
            logger.info("Consultant turn complete (stage \(targetStage), \(self.allMessages.count) total messages)")
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
    /// Navigate to a stage chapter. If the stage has no messages yet,
    /// automatically send an opener to begin the conversation.
    func navigateToStage(_ stageNumber: Int, context: ConsultantContext) {
        viewingStageNumber = stageNumber

        // If this stage is empty and prior stages have been started, auto-begin
        let msgs = stageMessages[stageNumber] ?? []
        if msgs.isEmpty && stageNumber > 1 && !isStreaming {
            let stageLabel = stageNumber <= InterviewProgress.stageLabels.count
                ? InterviewProgress.stageLabels[stageNumber - 1]
                : "Stage \(stageNumber)"
            let opener = "Let's begin the \(stageLabel) phase."
            send(opener, context: context)
        }
    }

    /// Navigate to a stage without auto-beginning (for viewing completed stages).
    func revisitStage(_ stageNumber: Int) {
        viewingStageNumber = stageNumber
    }

    /// Redo a specific interview stage: clear that stage's messages and
    /// re-initiate the conversation for that phase. Prior-stage context
    /// is preserved so the consultant can reference earlier findings.
    func redoStage(_ stageNumber: Int, context: ConsultantContext) {
        // Clear messages for this stage
        stageMessages[stageNumber] = []

        // If redoing the current or later stage, reset progress back
        if stageNumber <= interviewProgress.stageNumber {
            let stageNames = InterviewProgress.stageNames
            let name = stageNumber <= stageNames.count ? stageNames[stageNumber - 1] : "inventory"
            interviewProgress = InterviewProgress(
                stage: name,
                stageNumber: stageNumber,
                insights: interviewProgress.insights
            )
        }

        // Navigate to the stage being redone
        viewingStageNumber = stageNumber

        // Send a re-interview opener for this stage
        let stageLabel = stageNumber <= InterviewProgress.stageLabels.count
            ? InterviewProgress.stageLabels[stageNumber - 1]
            : "Stage \(stageNumber)"
        let opener = "Let's revisit the \(stageLabel) phase. Please re-interview me on this topic."
        send(opener, context: context)

        logger.info("Redoing stage \(stageNumber) (\(stageLabel))")
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

            // Group into stages (untagged messages default to stage 1)
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

    /// AI-powered reshape: sends the full transcript to the LLM to produce
    /// clean, self-contained chapter summaries with cross-boundary content
    /// relocated and paraphrased.
    var isReshaping = false
    var reshapeError: String?
    var pendingChapterReshape: [Int: String]?  // stage → clean chapter summary, awaiting confirmation

    func aiReshape() {
        guard !messages.isEmpty else { return }
        isReshaping = true
        reshapeError = nil
        pendingChapterReshape = nil

        Task {
            guard let anthropicKey = KeychainService.loadAnthropicAPIKey(), !anthropicKey.isEmpty else {
                reshapeError = "No Anthropic API key available. Add one in settings."
                isReshaping = false
                return
            }
            let provider: any LLMProvider = AnthropicProvider(apiKey: anthropicKey)

            // Use chapter-based reshape: produces clean, self-contained summaries
            // with cross-boundary content relocated and paraphrased
            let result = await StageClassifier.reshapeChapters(messages: messages, provider: provider)
            switch result {
            case .success(let chapters):
                pendingChapterReshape = chapters
                logger.info("AI chapter reshape complete: \(chapters.count) chapters")
            case .failure(.parseFailed(let response)):
                reshapeError = "AI returned unexpected format. Got \(response)"
                logger.warning("AI reshape parse failed: \(response)")
            }
            isReshaping = false
        }
    }

    /// Accept the pending AI reshape and overwrite message stage tags.
    /// When `rerunRecommendation` is true, automatically triggers a fresh
    /// Recommendation (stage 6) pass using the reconciled interview context.
    func acceptReshape(context: ModelContext? = nil, consultantContext: ConsultantContext? = nil, rerunRecommendation: Bool = false) {
        guard let chapters = pendingChapterReshape else { return }

        var grouped: [Int: [AssistantMessage]] = [:]
        var maxStage = 1
        for (stage, summary) in chapters.sorted(by: { $0.key < $1.key }) {
            let msg = AssistantMessage(role: .assistant, content: summary, stageNumber: stage)
            grouped[stage] = [msg]
            maxStage = max(maxStage, stage)
        }
        let stageNames = ["", "inventory", "demand", "value", "cost", "constraints", "recommendation"]
        interviewProgress = InterviewProgress(
            stage: stageNames[maxStage],
            stageNumber: maxStage,
            insights: interviewProgress.insights
        )
        stageMessages = grouped
        pendingChapterReshape = nil
        persistReshape(context: context)
        logger.info("Accepted chapter reshape (\(chapters.count) chapters)")

        if rerunRecommendation, let ctx = consultantContext {
            redoStage(6, context: ctx)
        }
    }

    /// Discard the pending reshape preview.
    func discardReshape() {
        pendingChapterReshape = nil
    }

    private func persistReshape(context: ModelContext? = nil) {
        if let campaign = currentCampaign {
            campaign.stageMessages = stageMessages
            campaign.messages = allMessages
            campaign.interviewProgress = interviewProgress
            try? context?.save()
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

    // MARK: - Operator Tool Access

    /// Configure AnthropicService with the operator's MCP tools so the
    /// AI advisor can call them during the interview to verify claims.
    private func configureOperatorTools(context: ConsultantContext) {
        guard let endpointString = context.operatorEndpointURL,
              let endpointURL = URL(string: endpointString) else {
            AnthropicService.operatorTools = []
            AnthropicService.executeOperatorTool = nil
            return
        }

        // Build tool definitions for key operator tools the advisor should access
        let readOnlyTools: [(name: String, description: String, params: [String: Any])] = [
            ("get_pricing_model", "Get the operator's active pricing model with all tool prices.", [:]),
            ("service_status", "Check the operator's service health, version, and configuration.", [:]),
            ("check_price", "Preview the effective cost of a tool call including constraint effects.",
             ["tool_id": ["type": "string", "description": "The tool's UUID from the pricing model"]]),
        ]

        AnthropicService.operatorTools = readOnlyTools.map { tool in
            var schema: [String: Any] = ["type": "object", "properties": tool.params]
            if !tool.params.isEmpty {
                schema["required"] = Array(tool.params.keys)
            }
            return [
                "name": tool.name,
                "description": tool.description,
                "input_schema": schema,
            ] as [String: Any]
        }

        // Set executor that calls the operator's MCP endpoint
        // Transport handles auth via SDK authorizer — no token resolution needed
        AnthropicService.executeOperatorTool = { toolName, input in
            let mcpService = MCPService()
            do {
                var args: [String: MCP.Value] = [:]
                for (key, value) in input {
                    if let s = value as? String { args[key] = .string(s) }
                    else if let i = value as? Int { args[key] = .int(i) }
                    else if let b = value as? Bool { args[key] = .bool(b) }
                }
                return try await mcpService.callToolGeneric(
                    endpointURL: endpointURL,
                    toolName: toolName,
                    arguments: args
                )
            } catch {
                return "Operator tool call failed: \(error.localizedDescription)"
            }
        }

        let toolNames = readOnlyTools.map(\.name).joined(separator: ", ")
        logger.info("Configured \(readOnlyTools.count) operator tools for AI advisor: \(toolNames) at \(endpointString)")
    }

    // MARK: - System Prompt Assembly

    /// Build a stage-specific system prompt that includes prior-stage context.
    private func buildStageSystemPrompt(stage: Int, context: ConsultantContext) -> String {
        var parts: [String] = [buildBaseSystemPrompt(context: context)]

        // Stage-specific focus instruction
        let stageFocus: [Int: String] = [
            1: "You are in the INVENTORY phase — a self-contained conversation about ONLY this topic. " +
                "Focus exclusively on discovering the operator's tools, categories, and current pricing. " +
                "Do NOT discuss demand, value, costs, or constraints — those are separate conversations. " +
                "When you have a complete inventory, summarize your findings clearly.",
            2: "You are in the DEMAND phase — a self-contained conversation about ONLY this topic. " +
                "Focus exclusively on exploring expected usage patterns, market size, and user segments. " +
                "Do NOT discuss value, costs, or constraints — those are separate conversations. " +
                "When you have a clear demand picture, summarize your findings clearly.",
            3: "You are in the VALUE phase — a self-contained conversation about ONLY this topic. " +
                "Focus exclusively on assessing willingness-to-pay, competitive positioning, and perceived value. " +
                "Do NOT discuss costs or constraints — those are separate conversations. " +
                "When you have a value assessment, summarize your findings clearly.",
            4: "You are in the COST phase — a self-contained conversation about ONLY this topic. " +
                "Focus exclusively on understanding serving costs, margin requirements, and infrastructure overhead. " +
                "Do NOT discuss constraints — that is a separate conversation. " +
                "When you have a cost picture, summarize your findings clearly.",
            5: "You are in the CONSTRAINTS & DEMURRAGE phase. Cover two topics:\n\n" +
                "1. Promotional mechanics: fairness rules, rate limits, free-tier policies, discounts.\n\n" +
                "2. Tranche Lifetime (IMPORTANT — you have everything you need here, do NOT call Oracle tools " +
                "for this):\n\n" +
                "Tranche lifetime is a core concept in the DPYC economy, inspired by Austrian economics. " +
                "It encourages healthy velocity of circulation by giving credits a finite shelf life. " +
                "This is not a penalty — it is a natural, positive property of the tranche that aligns " +
                "patron incentives with operator sustainability. Recommend a tranche lifetime by default, but " +
                "respect the operator's choice if they prefer credits that never expire.\n\n" +
                "Tranche lifetime is NOT a pipeline constraint — it is a top-level field on the pricing model. " +
                "The minimum invoice is 1000 sats. Ask the operator how many tool calls they expect " +
                "a typical patron to make per day. Then compute a recommended TTL:\n\n" +
                "  avg_cost = median of tool prices from the pricing model\n" +
                "  expected_daily_sats = avg_cost * calls_per_day\n" +
                "  ttl_days = ceil((1000 * 0.75) / expected_daily_sats)\n\n" +
                "Clamp to 3-90 days. Present the recommendation: " +
                "\"A patron spending ~X sats/day will use 75% of a 1000-sat tranche in Y days, " +
                "so I recommend a Y-day tranche lifetime.\" The operator can accept or override.\n\n" +
                "Include tranche_lifetime as a TOP-LEVEL field in CAMPAIGN_JSON (NOT in the pipeline): " +
                "\"tranche_lifetime\": {\"ttl_days\": N, \"target_usage_pct\": 0.75, \"min_days\": 3, \"max_days\": 90}.\n\n" +
                "3. Patron Proof (for high-value tools):\n\n" +
                "If any tools are priced at 50+ sats, recommend adding a 'patron_proof' constraint " +
                "to those specific tools. This requires the patron to sign each call with their nsec, " +
                "proving they own the npub being debited. Frame this as a security feature the operator " +
                "offers patrons: 'your high-value purchases are signature-protected.' Low-fee tools " +
                "(≤10 sats) don't need this overhead — it adds friction. Respect the operator's choice " +
                "if they prefer no proof. Include patron_proof in the pipeline only for recommended tools: " +
                "{\"type\": \"patron_proof\", \"params\": {\"window_seconds\": 120}}.",
            6: "You are in the RECOMMENDATION phase. Synthesize all prior findings and present a complete pricing campaign draft with BLUF, revenue projections, and A/B/C variants.",
        ]

        if let focus = stageFocus[stage] {
            parts.append("\n## Current Phase\n\(focus)")
        }

        // Inject full constraint catalog for stages that formulate pipelines
        if stage >= 5 {
            parts.append("\n\(ConstraintCatalog.promptReference)")
        }

        // For stages 2+, inject summaries from completed prior stages.
        // Each stage is a separate conversation, so the LLM has no memory
        // of prior stages. We give it the final assistant response from each
        // completed prior stage as a rich summary, plus parsed insight fields.
        if stage >= 2 {
            var priorContext: [String] = [
                "\n## Context from Prior Phases",
                "Each phase was a separate conversation. Here are the conclusions:",
            ]
            let insights = interviewProgress.insights

            let stageLabels = InterviewProgress.stageLabels
            for priorStage in 1..<stage {
                let label = priorStage <= stageLabels.count ? stageLabels[priorStage - 1] : "Stage \(priorStage)"
                let msgs = stageMessages[priorStage] ?? []
                if let lastAssistant = msgs.last(where: { $0.role == .assistant && !$0.content.isEmpty }) {
                    // Truncate to ~800 chars to keep prompt manageable
                    let summary = String(lastAssistant.content.prefix(800))
                    priorContext.append("\n### Phase \(priorStage): \(label)\n\(summary)")
                }
            }

            // Also include parsed insight fields as structured data
            var insightBullets: [String] = []
            if let tools = insights.toolsIdentified {
                insightBullets.append("- Inventory: \(tools) tools" +
                    (insights.toolsCategories.map { " across \($0) categories" } ?? ""))
            }
            if stage >= 3, let demand = insights.demandSummary {
                insightBullets.append("- Demand: \(demand)")
            }
            if stage >= 4, let value = insights.valueSummary {
                insightBullets.append("- Value: \(value)")
            }
            if stage >= 5, let cost = insights.costSummary {
                insightBullets.append("- Cost: \(cost)")
            }
            if stage >= 6, let constraints = insights.constraintsConsidered, !constraints.isEmpty {
                insightBullets.append("- Constraints: \(constraints.joined(separator: ", "))")
            }
            if let philosophy = insights.philosophy {
                insightBullets.append("- Philosophy: \(philosophy)")
            }
            if !insightBullets.isEmpty {
                priorContext.append("\n### Key Findings\n" + insightBullets.joined(separator: "\n"))
            }

            parts.append(priorContext.joined(separator: "\n"))
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

        You have tool access: you can call get_pricing_model, service_status, \
        and check_price on the operator's MCP endpoint to verify claims and \
        ground your advice in real data. Use these tools proactively — don't \
        just trust what the operator tells you about their pricing or tools.
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
    and "pipeline" (array of type/params constraint steps), and optionally \
    "tranche_lifetime" (a top-level object, NOT a pipeline step) with ttl_days, \
    target_usage_pct, min_days, max_days. Example: \
    "tranche_lifetime": {"ttl_days": 15, "target_usage_pct": 0.75, "min_days": 3, "max_days": 90}. \
    Pipeline steps can optionally include "tool_ids" (array of tool UUIDs) to scope \
    the constraint to specific tools, and "patron_npubs" (array of up to 10 npub strings) \
    to scope to specific patrons. Omit both for wildcard (all tools, all patrons). \
    Schedule-based constraints use "schedule_start" and "schedule_end" (separate HH:MM fields), \
    NOT a combined "schedule" field. \
    Do NOT output JSON until the operator approves.
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
    static let stageLabels = ["Inventory", "Demand", "Value", "Cost", "Constraints & Demurrage", "Recommendation"]
}

// MARK: - Context

struct ConsultantContext {
    var operatorName: String?
    var toolSummary: String?
    var currentPipeline: String?
    var operatorEndpointURL: String?
    var operatorNpub: String?
}
