import Foundation
import SwiftData

/// A saved pricing consultant conversation.
///
/// Persists the full message history, operator context, and campaign name
/// so the analyst can resume interviews across sessions.
@Model
final class Campaign {
    var name: String = ""
    var operatorNpub: String = ""
    var operatorDisplayName: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// Serialized messages as JSON array of {role, content, timestamp}.
    var messagesJSON: Data = Data()

    /// Serialized interview progress JSON, if any.
    var progressJSON: Data?

    /// Serialized revenue projections JSON, if any.
    var projectionsJSON: Data?

    /// Saved second-opinion review text (markdown from Grok/Claude reviewer).
    var secondOpinionText: String?

    /// Serialized InterviewAnalysis JSON (stage classifications + insights).
    var analysisJSON: Data?

    /// Serialized PricingProposal JSON (pipeline + tool prices + projections).
    var proposalJSON: Data?

    /// Serialized PeerReview JSON (structured reviewer feedback).
    var peerReviewJSON: Data?

    /// Per-stage message storage — keys are stage numbers (1-6).
    /// Lightweight migration: defaults to nil for existing campaigns.
    var stageMessagesJSON: Data?

    /// Whether this campaign is the one currently deployed to its operator.
    var isDeployed: Bool = false

    /// Whether this campaign has been put away (removed from the sidebar workspace slots).
    /// Put-away campaigns remain in the persistent store and can be loaded back into a slot.
    var isHidden: Bool = false

    init(
        name: String,
        operatorNpub: String,
        operatorDisplayName: String,
        messages: [AssistantMessage] = []
    ) {
        self.name = name
        self.operatorNpub = operatorNpub
        self.operatorDisplayName = operatorDisplayName
        self.createdAt = Date()
        self.updatedAt = Date()
        self.messagesJSON = Campaign.encode(messages)
        self.progressJSON = nil
    }

    /// Computed accessor for interview progress.
    var interviewProgress: InterviewProgress? {
        get {
            guard let data = progressJSON else { return nil }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try? decoder.decode(InterviewProgress.self, from: data)
        }
        set {
            if let value = newValue {
                let encoder = JSONEncoder()
                encoder.keyEncodingStrategy = .convertToSnakeCase
                progressJSON = try? encoder.encode(value)
            } else {
                progressJSON = nil
            }
            updatedAt = Date()
        }
    }

    /// Computed accessor for revenue projections.
    var revenueProjections: CampaignProjections? {
        get {
            guard let data = projectionsJSON else { return nil }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try? decoder.decode(CampaignProjections.self, from: data)
        }
        set {
            if let value = newValue {
                let encoder = JSONEncoder()
                encoder.keyEncodingStrategy = .convertToSnakeCase
                projectionsJSON = try? encoder.encode(value)
            } else {
                projectionsJSON = nil
            }
            updatedAt = Date()
        }
    }

    /// Computed accessor for interview analysis.
    var analysis: InterviewAnalysis? {
        get {
            guard let data = analysisJSON else { return nil }
            return try? JSONDecoder().decode(InterviewAnalysis.self, from: data)
        }
        set {
            if let value = newValue {
                analysisJSON = try? JSONEncoder().encode(value)
            } else {
                analysisJSON = nil
            }
            updatedAt = Date()
        }
    }

    /// Computed accessor for pricing proposal.
    var proposal: PricingProposal? {
        get {
            guard let data = proposalJSON else { return nil }
            return try? JSONDecoder().decode(PricingProposal.self, from: data)
        }
        set {
            if let value = newValue {
                proposalJSON = try? JSONEncoder().encode(value)
            } else {
                proposalJSON = nil
            }
            updatedAt = Date()
        }
    }

    /// Computed accessor for peer review.
    var peerReview: PeerReview? {
        get {
            guard let data = peerReviewJSON else { return nil }
            return try? JSONDecoder().decode(PeerReview.self, from: data)
        }
        set {
            if let value = newValue {
                peerReviewJSON = try? JSONEncoder().encode(value)
            } else {
                peerReviewJSON = nil
            }
            updatedAt = Date()
        }
    }

    // MARK: - Message Serialization

    var messages: [AssistantMessage] {
        get { Campaign.decode(messagesJSON) }
        set {
            messagesJSON = Campaign.encode(newValue)
            updatedAt = Date()
        }
    }

    /// Computed accessor for per-stage message dictionary.
    var stageMessages: [Int: [AssistantMessage]] {
        get {
            guard let data = stageMessagesJSON,
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return [:]
            }
            var result: [Int: [AssistantMessage]] = [:]
            for (key, value) in dict {
                guard let stageNum = Int(key),
                      let msgData = try? JSONSerialization.data(withJSONObject: value),
                      let msgs = try? JSONSerialization.jsonObject(with: msgData) as? [[String: Any]] else {
                    continue
                }
                result[stageNum] = Campaign.decodeDicts(msgs)
            }
            return result
        }
        set {
            var dict: [String: Any] = [:]
            for (stage, msgs) in newValue {
                dict["\(stage)"] = Campaign.encodeDicts(msgs)
            }
            stageMessagesJSON = try? JSONSerialization.data(withJSONObject: dict)
            updatedAt = Date()
        }
    }

    /// Migrate flat messages to per-stage storage. Returns true if migration occurred.
    @discardableResult
    func migrateToStageMessages() -> Bool {
        let flat = messages
        guard !flat.isEmpty else { return false }

        var grouped: [Int: [AssistantMessage]] = [:]
        for msg in flat {
            let stage = msg.stageNumber ?? 1
            grouped[stage, default: []].append(msg)
        }
        stageMessages = grouped
        return true
    }

    static func encode(_ messages: [AssistantMessage]) -> Data {
        let dicts: [[String: Any]] = messages.map { msg in
            var dict: [String: Any] = [
                "role": msg.role.rawValue,
                "content": msg.content,
                "timestamp": ISO8601DateFormatter().string(from: msg.timestamp),
            ]
            if let stage = msg.stageNumber {
                dict["stage_number"] = stage
            }
            return dict
        }
        return (try? JSONSerialization.data(withJSONObject: dicts)) ?? Data()
    }

    static func decode(_ data: Data) -> [AssistantMessage] {
        guard let dicts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return decodeDicts(dicts)
    }

    static func decodeDicts(_ dicts: [[String: Any]]) -> [AssistantMessage] {
        let formatter = ISO8601DateFormatter()
        return dicts.compactMap { dict in
            guard let roleStr = dict["role"] as? String,
                  let role = AssistantMessage.Role(rawValue: roleStr),
                  let content = dict["content"] as? String else { return nil }
            let timestamp = (dict["timestamp"] as? String).flatMap { formatter.date(from: $0) } ?? Date()
            let stageNumber = dict["stage_number"] as? Int
            return AssistantMessage(role: role, content: content, timestamp: timestamp, stageNumber: stageNumber)
        }
    }

    static func encodeDicts(_ messages: [AssistantMessage]) -> [[String: Any]] {
        messages.map { msg in
            var dict: [String: Any] = [
                "role": msg.role.rawValue,
                "content": msg.content,
                "timestamp": ISO8601DateFormatter().string(from: msg.timestamp),
            ]
            if let stage = msg.stageNumber {
                dict["stage_number"] = stage
            }
            return dict
        }
    }

    // MARK: - Export for Community Sharing

    /// Export campaign as a JSON string suitable for import.
    func exportJSON() -> String {
        let formatter = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "name": name,
            "operator_npub": operatorNpub,
            "operator_display_name": operatorDisplayName,
            "created_at": formatter.string(from: createdAt),
            "updated_at": formatter.string(from: updatedAt),
            "is_deployed": isDeployed,
        ]

        if let proposal = proposal {
            if let data = try? JSONEncoder().encode(proposal),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                dict["proposal"] = obj
            }
        }

        if let progress = interviewProgress {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            if let data = try? encoder.encode(progress),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                dict["interview_progress"] = obj
            }
        }

        if let projections = revenueProjections {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            if let data = try? encoder.encode(projections),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                dict["revenue_projections"] = obj
            }
        }

        if let review = peerReview {
            if let data = try? JSONEncoder().encode(review),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                dict["peer_review"] = obj
            }
        }

        if let opinion = secondOpinionText, !opinion.isEmpty {
            dict["second_opinion"] = opinion
        }

        if let analysis = analysis {
            if let data = try? JSONEncoder().encode(analysis),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                dict["interview_analysis"] = obj
            }
        }

        // Full interview transcript
        let allMsgs = messages
        if !allMsgs.isEmpty {
            dict["interview_messages"] = Campaign.encodeDicts(allMsgs)
        }

        let data = (try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Export campaign as a rich Markdown document for human reading.
    ///
    /// Includes everything a reader needs to understand the campaign's
    /// value proposition: overview metrics, pricing philosophy, tool prices,
    /// constraint pipeline rationale, revenue projections, the full peer
    /// review, and the complete interview conversation.
    func exportMarkdown() -> String {
        let stageLabels = InterviewProgress.stageLabels

        var md = "# \(name)\n\n"
        md += "**Operator:** \(operatorDisplayName)\n"
        md += "**Created:** \(createdAt.formatted(date: .long, time: .omitted))\n"
        md += "**Updated:** \(updatedAt.formatted(date: .long, time: .omitted))\n"
        if isDeployed { md += "**Status:** Deployed\n" }
        if let progress = interviewProgress {
            let label = progress.stageNumber <= stageLabels.count
                ? stageLabels[progress.stageNumber - 1]
                : "Stage \(progress.stageNumber)"
            md += "**Interview Stage:** \(progress.stageNumber)/6 (\(label))\n"
        }
        md += "\n---\n\n"

        // ── Bottom Line Up Front ──────────────────────────────────
        let insights = interviewProgress?.insights
        let projections = proposal?.projections ?? revenueProjections

        if insights != nil || projections != nil {
            md += "## Bottom Line Up Front\n\n"

            if let philosophy = insights?.philosophy {
                md += "**Pricing Philosophy:** \(philosophy.capitalized)\n\n"
            }

            if let moderate = projections?.moderate {
                md += "**Projected Revenue (moderate):** "
                md += "\(moderate.revenueSats.formatted()) sats/mo "
                md += "($\(String(format: "%.2f", moderate.revenueUsd))/mo)\n\n"
            }

            if let tc = projections?.toolCount, let avg = projections?.avgPriceSats {
                md += "**Tools:** \(tc) total, \(avg) sats average price\n\n"
            }

            if let constraints = insights?.constraintsConsidered, !constraints.isEmpty {
                md += "**Constraints:** \(constraints.joined(separator: ", "))\n\n"
            }
        }

        // ── Tool Prices ──────────────────────────────────────────
        if let tools = proposal?.toolPrices, !tools.isEmpty {
            md += "## Tool Prices\n\n"
            md += "| Tool | Price (sats) | Category | Intent |\n"
            md += "|------|-------------|----------|--------|\n"
            for tool in tools {
                md += "| \(tool.toolName) | \(tool.priceSats) | \(tool.category) | \(tool.intent) |\n"
            }
            md += "\n"
        }

        // ── Constraint Pipeline ──────────────────────────────────
        if let pipeline = proposal?.pipeline, !pipeline.isEmpty {
            md += "## Constraint Pipeline\n\n"
            md += "The constraint pipeline evaluates each tool invocation to determine "
            md += "the effective price. Steps execute in order; each can modify the price "
            md += "or deny access.\n\n"
            for (i, step) in pipeline.enumerated() {
                let typeName = step.type.replacingOccurrences(of: "_", with: " ").capitalized
                md += "### Step \(i + 1): \(typeName)\n\n"
                for (key, value) in step.params.sorted(by: { $0.key < $1.key }) {
                    md += "- **\(key):** \(value)\n"
                }
                md += "\n"
            }
        }

        // ── Revenue Projections ──────────────────────────────────
        if let proj = projections, !proj.projections.isEmpty {
            md += "## Revenue Projections\n\n"

            if proj.tam != nil || proj.sam != nil || proj.som != nil {
                if let tam = proj.tam { md += "- **TAM:** \(tam)\n" }
                if let sam = proj.sam { md += "- **SAM:** \(sam)\n" }
                if let som = proj.som { md += "- **SOM:** \(som)\n" }
                md += "\n"
            }

            md += "| Scenario | Users/Mo | Calls/User | Sats/Mo | USD/Mo |\n"
            md += "|----------|---------|------------|---------|--------|\n"
            for rp in proj.projections {
                md += "| \(rp.scenario.capitalized) "
                md += "| \(rp.monthlyUsers) "
                md += "| \(rp.callsPerUserPerMonth) "
                md += "| \(rp.revenueSats.formatted()) "
                md += "| $\(String(format: "%.2f", rp.revenueUsd)) |\n"
            }
            md += "\n"
        }

        // ── Peer Review ──────────────────────────────────────────
        if let review = peerReview {
            md += "## Peer Review\n\n"
            md += "**Reviewer:** \(review.providerName)\n"
            if let verdict = review.verdict {
                let label: String
                switch verdict {
                case .approve: label = "Approved"
                case .approveWithReservations: label = "Approved with Reservations"
                case .reworkRecommended: label = "Rework Recommended"
                case .reject: label = "Rejected"
                }
                md += "**Verdict:** \(label)\n\n"
            }

            for section in review.sections {
                md += "### \(section.title)\n\n"
                md += "\(section.content)\n\n"
            }

            if let changes = review.suggestedChanges, !changes.isEmpty {
                md += "### Suggested Changes\n\n"
                md += "\(changes)\n\n"
            }
        }

        // Also include the raw second opinion if different from structured review
        if peerReview == nil, let opinion = secondOpinionText, !opinion.isEmpty {
            md += "## Second Opinion\n\n"
            md += opinion
            md += "\n\n"
        }

        // ── Full Interview ───────────────────────────────────────
        let allMsgs = messages
        if !allMsgs.isEmpty {
            md += "## Interview Transcript\n\n"
            md += "The complete pricing consultant interview, "
            md += "\(allMsgs.count) messages across "
            md += "\(Set(allMsgs.compactMap(\.stageNumber)).count) stages.\n\n"

            var lastStage: Int?
            for msg in allMsgs {
                let stage = msg.stageNumber ?? 0
                if stage != lastStage, stage > 0, stage <= stageLabels.count {
                    md += "### Stage \(stage): \(stageLabels[stage - 1])\n\n"
                    lastStage = stage
                }
                let role = msg.role == .user ? "**Operator**" : "**Consultant**"
                md += "\(role):\n\n"
                md += "\(msg.content)\n\n"
            }
        }

        // ── Footer ───────────────────────────────────────────────
        md += "---\n\n"
        md += "*Exported from [Pricing Studio](https://github.com/lonniev/tollbooth-pricing-studio) "
        md += "— part of the [DPYC](https://github.com/lonniev/dpyc-community) ecosystem.*\n"

        return md
    }
}
