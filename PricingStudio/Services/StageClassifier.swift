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

    // MARK: - Error

    enum ClassificationError: Error {
        case parseFailed(response: String)
    }
}
