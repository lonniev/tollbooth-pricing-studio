import Foundation
import OSLog

private let logger = Logger(subsystem: "com.tollbooth.dpyc.PricingStudio", category: "StageClassifier")

/// Stateless service for classifying interview messages into stages (1–6).
///
/// AI-powered reshape: produces clean, self-contained chapter summaries
/// from a pricing interview transcript.
enum StageClassifier {

    // MARK: - AI Reshape with Chapter Boundary Cleanup

    /// Reshape the transcript into clean, self-contained chapter summaries.
    /// Rewrites each chapter to relocate cross-boundary content and
    /// paraphrase where needed so each chapter reads as a standalone unit.
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
        5 = Constraints & Tranche Lifetime (free tiers, rate limits, tranche lifetime, pipeline rules)
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

        // Parse the JSON object from the response, stripping markdown fences
        var cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip ```json ... ``` fences
        if cleaned.hasPrefix("```") {
            if let bodyStart = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: bodyStart)...])
            }
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let jsonString: String
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}") {
            jsonString = String(cleaned[start...end])
        } else {
            jsonString = cleaned
        }

        guard let data = jsonString.data(using: .utf8),
              let rawObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !rawObj.isEmpty else {
            logger.warning("AI reshape parse failed: \(response.prefix(300))")
            return .failure(.parseFailed(response: String(response.prefix(300))))
        }

        // Convert to [Int: String] — values may be strings or nested objects
        var result: [Int: String] = [:]
        for (key, value) in rawObj {
            guard let stage = Int(key), (1...6).contains(stage) else { continue }
            if let s = value as? String {
                result[stage] = s
            } else if let data = try? JSONSerialization.data(withJSONObject: value),
                      let s = String(data: data, encoding: .utf8) {
                result[stage] = s
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
