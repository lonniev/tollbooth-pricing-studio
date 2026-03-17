import Foundation
import OSLog

private let logger = Logger(subsystem: "com.tollbooth.dpyc.PricingStudio", category: "ResponseParser")

/// Stateless service for extracting structured data from LLM responses.
///
/// Owns all the regex parsing that was previously inline in
/// `PricingConsultantViewModel` — PROGRESS comments, REVENUE comments,
/// CAMPAIGN_JSON comments, and display cleanup.
enum ResponseParser {

    // MARK: - Progress Extraction

    /// Regex to match `<!-- PROGRESS {...} -->` — uses dotMatchesLineSeparators
    /// so the JSON can span lines if Claude splits it.
    private static let progressPattern = try! NSRegularExpression(
        pattern: #"<!--\s*PROGRESS\s+(\{[\s\S]*?\})\s*-->"#,
        options: [.dotMatchesLineSeparators]
    )

    /// Strip the PROGRESS comment from text and parse the embedded JSON.
    static func extractProgress(from text: String) -> (stripped: String, progress: InterviewProgress?) {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = progressPattern.firstMatch(in: text, range: range),
              let jsonRange = Range(match.range(at: 1), in: text) else {
            let suffix = text.suffix(200)
            logger.debug("PROGRESS parse: no match. Tail: \(suffix)")
            return (text, nil)
        }

        let jsonString = String(text[jsonRange])
        let stripped = progressPattern.stringByReplacingMatches(
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

    // MARK: - Revenue Extraction

    /// Regex to match `<!-- REVENUE {...} -->`.
    private static let revenuePattern = try! NSRegularExpression(
        pattern: #"<!--\s*REVENUE\s+(\{[\s\S]*?\})\s*-->"#,
        options: [.dotMatchesLineSeparators]
    )

    /// Strip the REVENUE comment from text and parse projected revenue.
    static func extractRevenue(from text: String) -> (stripped: String, projections: CampaignProjections?) {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = revenuePattern.firstMatch(in: text, range: range),
              let jsonRange = Range(match.range(at: 1), in: text) else {
            return (text, nil)
        }

        let jsonString = String(text[jsonRange])
        let stripped = revenuePattern.stringByReplacingMatches(
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

    // MARK: - Campaign JSON Extraction

    /// Extract campaign pipeline JSON from `<!-- CAMPAIGN_JSON {...} -->`,
    /// JSON code fences, or bare JSON objects.
    static func extractCampaignJSON(from text: String) -> String? {
        // Try hidden comment format first: <!-- CAMPAIGN_JSON {...} -->
        let campaignPattern = try! NSRegularExpression(
            pattern: #"<!--\s*CAMPAIGN_JSON\s+(\{[\s\S]*?\})\s*-->"#,
            options: [.dotMatchesLineSeparators]
        )
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = campaignPattern.firstMatch(in: text, range: nsRange),
           let jsonRange = Range(match.range(at: 1), in: text) {
            let candidate = String(text[jsonRange])
            if isValidJSON(candidate) { return candidate }
        }

        // Fallback: JSON code fence
        if let fencedRange = text.range(of: #"```json\s*\n([\s\S]*?)\n```"#, options: .regularExpression) {
            let inner = text[fencedRange]
            let stripped = inner
                .replacingOccurrences(of: #"^```json\s*\n"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\n```$"#, with: "", options: .regularExpression)
            if isValidJSON(stripped) { return stripped }
        }

        // Last resort: find outermost balanced braces
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

    // MARK: - Display Cleanup

    /// Strip machine-readable artifacts from displayed message content:
    /// - JSON code fences (```json ... ```) — extracted separately for pipeline apply
    /// - HTML comments (<!-- ... -->) that weren't caught by PROGRESS/REVENUE parsing
    /// - Excessive blank lines left after stripping
    static func cleanForDisplay(_ text: String) -> String {
        var cleaned = text

        // Strip JSON code fences (keep the prose around them)
        cleaned = cleaned.replacingOccurrences(
            of: #"```json\s*\n[\s\S]*?\n```"#,
            with: "",
            options: .regularExpression
        )

        // Strip any remaining HTML comments
        cleaned = cleaned.replacingOccurrences(
            of: #"<!--[\s\S]*?-->"#,
            with: "",
            options: .regularExpression
        )

        // Collapse runs of 3+ blank lines into 2
        cleaned = cleaned.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Review Section Parsing

    /// Parse a reviewer response into titled sections based on markdown headings.
    static func parseReviewSections(from text: String) -> [ReviewSection] {
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
                    .trimmingCharacters(in: .init(charactersIn: " \u{2014}-:"))
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }
        flushSection()

        return result
    }

    /// Map section titles to SF Symbol icons and detect verdict sections.
    static func sectionMeta(for title: String, content: String) -> (String, ReviewVerdict?) {
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
            let verdict: ReviewVerdict?
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

    /// Detect if the reviewer suggested changes and extract the alternatives section text.
    static func detectSuggestedChanges(from text: String) -> (hasSuggestions: Bool, suggestionsText: String) {
        let upper = text.uppercased()
        let hasAlternatives = upper.contains("ALTERNATIVE") || upper.contains("SUGGESTION")
        let isCleanApprove = upper.contains("APPROVE") && !upper.contains("RESERVATION") && !upper.contains("REWORK") && !upper.contains("REJECT")

        let hasSuggestions = hasAlternatives && !isCleanApprove

        guard hasSuggestions else { return (false, "") }

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
                if (trimmed.hasPrefix("#") || trimmed.range(of: #"^\d+\.\s+\*\*"#, options: .regularExpression) != nil) && !trimmed.lowercased().contains("alternative") {
                    break
                }
                captured.append(line)
            }
        }

        return (true, captured.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Stage Transition Splitting

    /// Split assistant messages that span two stages into separate messages.
    ///
    /// When the consultant responds to a user's answer AND asks the next stage's
    /// question in a single message, the first part (commentary) belongs to the
    /// previous stage and the second part (new question) belongs to the new stage.
    ///
    /// Detection: finds the first `---` (horizontal rule) separator in assistant
    /// messages at stage boundaries. Content before the rule stays in the previous
    /// stage; content after starts the new stage.
    static func splitStageTransitions(_ messages: [AssistantMessage]) -> [AssistantMessage] {
        guard messages.count >= 3 else { return messages }

        var result: [AssistantMessage] = []

        for i in messages.indices {
            let msg = messages[i]

            // Only split assistant messages that advanced the stage past the previous message
            guard msg.role == .assistant,
                  let currentStage = msg.stageNumber,
                  i > 0,
                  let previousStage = messages[i - 1].stageNumber,
                  currentStage > previousStage else {
                result.append(msg)
                continue
            }

            // Look for a horizontal rule separator (--- on its own line)
            let lines = msg.content.components(separatedBy: "\n")
            let hrIndex = lines.firstIndex { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed == "---" || trimmed == "***" || trimmed == "___"
            }

            guard let splitLine = hrIndex else {
                result.append(msg)
                continue
            }

            let beforeLines = Array(lines.prefix(splitLine))
            let afterLines = Array(lines.suffix(from: lines.index(after: splitLine)))
            let beforeText = beforeLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let afterText = afterLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            // Only split if both halves have meaningful content
            guard beforeText.count >= 40, afterText.count >= 40 else {
                result.append(msg)
                continue
            }

            // First part: commentary on previous answer → previous stage
            result.append(AssistantMessage(
                role: .assistant,
                content: beforeText,
                timestamp: msg.timestamp,
                stageNumber: previousStage
            ))
            // Second part: new question → current (new) stage
            result.append(AssistantMessage(
                role: .assistant,
                content: afterText,
                timestamp: msg.timestamp,
                stageNumber: currentStage
            ))

            logger.info("Split message \(i) at HR: stage \(previousStage) (\(beforeText.count) chars) + stage \(currentStage) (\(afterText.count) chars)")
        }

        return result
    }

    // MARK: - Helpers

    private static func isValidJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}
