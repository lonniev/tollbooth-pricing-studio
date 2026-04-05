import Foundation
import OSLog

private let logger = Logger(subsystem: "com.tollbooth.dpyc.PricingStudio", category: "StageClassifier")

/// Stateless service for classifying interview messages into stages (1–6).
///
/// Two strategies: AI-powered classification via LLM, and a keyword
/// heuristic fallback for offline use.
enum StageClassifier {

    // MARK: - AI Classification

    /// Send the transcript to an LLM to classify each message into stages 1–6.
    /// Returns a per-message array of stage numbers.
    static func classifyViaAI(messages: [AssistantMessage], provider: any LLMProvider) async -> Result<[Int], ClassificationError> {
        guard !messages.isEmpty else { return .success([]) }

        // Build a numbered transcript
        var transcript = ""
        for (i, msg) in messages.enumerated() {
            let role = msg.role == .user ? "Operator" : "Consultant"
            let preview = String(msg.content.prefix(300))
            transcript += "[\(i)] \(role): \(preview)\n\n"
        }

        let systemPrompt = """
        You are classifying messages in a pricing interview transcript into exactly 6 stages:
        1 = Inventory (what tools/services does the operator offer)
        2 = Demand (who are the users, usage patterns, philosophy/framing)
        3 = Value (willingness to pay, economic value delivered, ROI)
        4 = Cost (operator's cost to serve, margins, infrastructure)
        5 = Constraints (free tiers, rate limits, surge pricing, pipeline rules)
        6 = Recommendation (final pricing proposal, revenue projections, approval)

        The interview flows forward through these stages in order. A stage may \
        span multiple messages. Stages are never revisited — once the conversation \
        moves to a later stage, earlier topics mentioned in passing do not change \
        the stage assignment.

        For each message index, output ONLY a JSON array of integers representing \
        the stage number. Example for 5 messages: [1, 1, 2, 2, 3]

        Output nothing else — no explanation, no markdown, just the JSON array.
        """

        let userMessage = "Classify each message:\n\n\(transcript)"
        let apiMessages: [[String: String]] = [
            ["role": "user", "content": userMessage]
        ]

        var response = ""
        let stream = provider.streamCompletion(
            messages: apiMessages,
            systemPrompt: systemPrompt,
            maxTokens: 1024
        )
        for await token in stream {
            response += token
        }

        // Parse the JSON array from the response
        let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonString: String
        if let start = cleaned.firstIndex(of: "["),
           let end = cleaned.lastIndex(of: "]") {
            jsonString = String(cleaned[start...end])
        } else {
            jsonString = cleaned
        }

        guard let data = jsonString.data(using: .utf8),
              let stages = try? JSONDecoder().decode([Int].self, from: data),
              !stages.isEmpty else {
            logger.warning("AI classify parse failed: \(response.prefix(200))")
            return .failure(.parseFailed(response: String(response.prefix(200))))
        }

        let reconciled = reconcileCount(stages: stages, messageCount: messages.count)
        logger.info("AI classification complete: \(reconciled)")
        return .success(reconciled)
    }

    // MARK: - Keyword Classification

    /// Classify messages by keyword heuristics (offline fallback).
    /// Returns a per-message array of stage numbers.
    static func classifyByKeywords(messages: [AssistantMessage]) -> [Int] {
        var currentStage = 1
        var result: [Int] = []

        for msg in messages {
            if let existing = msg.stageNumber {
                currentStage = max(currentStage, existing)
                result.append(currentStage)
                continue
            }

            let text = msg.content.lowercased()
            if let detected = detectStageByKeywords(text), detected > currentStage {
                currentStage = detected
            }
            result.append(currentStage)
        }

        return result
    }

    /// Keyword heuristic to detect interview stage transitions.
    ///
    /// Keywords are chosen to match **transition signals** — the phrases that
    /// indicate the consultant is moving to a new topic — not general vocabulary
    /// that appears throughout the interview.
    static func detectStageByKeywords(_ text: String) -> Int? {
        let stageKeywords: [(Int, [String])] = [
            (6, ["draft campaign", "here's the pricing", "final design",
                 "bluf", "proposed tool pricing", "campaign json", "approve this",
                 "do you approve", "variant a", "variant b", "variant c",
                 "revenue projection", "revenue forecast", "tam / sam", "tam/sam",
                 "monthly revenue", "3-scenario", "three scenario"]),
            (5, ["constraint question", "treat specially", "rate limiting",
                 "surge pricing", "free tier", "pipeline", "free_trial",
                 "loyalty_discount", "bulk_bonus", "permanently free",
                 "should remain free", "demand control"]),
            (4, ["cost side", "cost you to serve", "what does it cost",
                 "marginal cost", "near-zero", "cost structure", "cost floor",
                 "monthly subscription", "hosting cost", "infrastructure cost",
                 "backend cost", "serving cost", "azure vm"]),
            (3, ["value question", "value ceiling", "value signal",
                 "willingness to pay", "wtp", "economic value",
                 "cognitive leverage", "how much would", "pricing power",
                 "price sensitiv", "worth paying", "roi",
                 "productive session", "career or business outcome"]),
            (2, ["demand", "philosophy", "primary users", "who are your",
                 "usage pattern", "how frequently", "who's calling",
                 "target market", "user profile", "high-loyalty",
                 "low-frequency", "business-first", "mission-driven"]),
        ]

        var bestStage: Int?
        var bestScore = 0

        for (stage, keywords) in stageKeywords {
            let score = keywords.filter({ text.contains($0) }).count
            if score >= 2 && score > bestScore {
                bestScore = score
                bestStage = stage
            }
        }

        // Single-keyword fallback only for very distinctive phrases
        if bestStage == nil {
            let uniqueTransitions: [(Int, [String])] = [
                (6, ["draft campaign", "campaign json", "3-scenario", "tam / sam"]),
                (5, ["free_trial", "loyalty_discount", "bulk_bonus", "surge_pricing"]),
                (4, ["cost you to serve", "near-zero marginal cost", "cost floor"]),
                (3, ["willingness to pay", "cognitive leverage", "productive session"]),
                (2, ["primary users", "who's calling these tools"]),
            ]
            for (stage, phrases) in uniqueTransitions {
                if phrases.contains(where: { text.contains($0) }) {
                    bestStage = stage
                    break
                }
            }
        }

        return bestStage
    }

    // MARK: - Reconciliation

    /// Pad or trim a stage array to match the message count.
    static func reconcileCount(stages: [Int], messageCount: Int) -> [Int] {
        var reconciled = stages.map { max(1, min(6, $0)) }
        if reconciled.count < messageCount {
            let lastStage = reconciled.last ?? 1
            reconciled.append(contentsOf: Array(repeating: lastStage, count: messageCount - reconciled.count))
        } else if reconciled.count > messageCount {
            reconciled = Array(reconciled.prefix(messageCount))
        }
        return reconciled
    }

    // MARK: - AI Reshape with Chapter Boundary Cleanup

    /// Reshape the transcript into clean, self-contained chapter summaries.
    /// Unlike classifyViaAI (which just re-tags messages), this rewrites
    /// each chapter to relocate cross-boundary content and paraphrase
    /// where needed so each chapter reads as a complete, standalone unit.
    ///
    /// Returns a dict of stage number → cleaned chapter summary text.
    static func reshapeChapters(
        messages: [AssistantMessage],
        provider: any LLMProvider
    ) async -> Result<[Int: String], ClassificationError> {
        guard !messages.isEmpty else { return .success([:]) }

        var transcript = ""
        for (i, msg) in messages.enumerated() {
            let role = msg.role == .user ? "Operator" : "Consultant"
            transcript += "[\(i)] \(role): \(msg.content)\n\n---\n\n"
        }

        let systemPrompt = """
        You are an editor reshaping a pricing interview transcript into 6 clean chapters.

        The 6 stages are:
        1 = Inventory (tools, categories, current pricing)
        2 = Demand (users, usage patterns, market size)
        3 = Value (willingness to pay, competitive positioning)
        4 = Cost (serving costs, margins, infrastructure)
        5 = Constraints (free tiers, rate limits, demurrage, pipeline rules)
        6 = Recommendation (final pricing proposal, revenue projections)

        PROBLEM: The interviewer naturally bleeds across topic boundaries:
        - Offers advice on Topic A but introduces Topic B in the same response
        - Opens Topic B with a concluding remark about Topic A
        - Complete coverage of one topic is scattered between adjacent chapters

        YOUR TASK: Produce a clean summary for each chapter (1-6) that:
        1. Contains ALL content relevant to that topic, even if it appeared in an adjacent chapter's dialog
        2. MOVES cross-boundary fragments to the chapter where they topically belong
        3. PARAPHRASES when needed so each chapter reads naturally as a standalone unit
        4. Preserves the operator's actual statements and the consultant's advice — don't invent new content
        5. Omits pleasantries, transitions, and meta-commentary that don't carry substance

        Output a JSON object with keys "1" through "6", each containing the chapter summary as a string.
        Only include chapters that have substantive content. Use markdown formatting in the summaries.

        Example format:
        {
          "1": "## Inventory\\n\\nThe operator offers 12 tools across 3 categories...",
          "2": "## Demand\\n\\nPrimary users are financial advisors who...",
          "3": "## Value\\n\\n..."
        }

        Output ONLY the JSON object — no explanation, no markdown fences.
        """

        let userMessage = "Reshape this interview transcript into clean chapters:\n\n\(transcript)"
        let apiMessages: [[String: String]] = [
            ["role": "user", "content": userMessage]
        ]

        var response = ""
        let stream = provider.streamCompletion(
            messages: apiMessages,
            systemPrompt: systemPrompt,
            maxTokens: 8192
        )
        for await token in stream {
            response += token
        }

        // Parse the JSON object from the response
        let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonString: String
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}") {
            jsonString = String(cleaned[start...end])
        } else {
            jsonString = cleaned
        }

        guard let data = jsonString.data(using: .utf8),
              let chapters = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              !chapters.isEmpty else {
            logger.warning("AI reshape parse failed: \(response.prefix(200))")
            return .failure(.parseFailed(response: String(response.prefix(200))))
        }

        // Convert string keys to int keys
        var result: [Int: String] = [:]
        for (key, value) in chapters {
            if let stage = Int(key), (1...6).contains(stage) {
                result[stage] = value
            }
        }

        logger.info("AI reshape complete: \(result.count) chapters")
        return .success(result)
    }

    // MARK: - Error

    enum ClassificationError: Error {
        case parseFailed(response: String)
    }
}
