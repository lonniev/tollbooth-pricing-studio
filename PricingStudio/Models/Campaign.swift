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

        let data = (try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Export campaign as a Markdown summary for human reading.
    func exportMarkdown() -> String {
        var md = "# \(name)\n\n"
        md += "**Operator:** \(operatorDisplayName)\n"
        md += "**Created:** \(createdAt.formatted(date: .long, time: .omitted))\n"
        if isDeployed { md += "**Status:** Deployed\n" }
        md += "\n---\n\n"

        // Proposal summary
        if let proposal = proposal {
            md += "## Pricing Proposal\n\n"

            if let tools = proposal.toolPrices, !tools.isEmpty {
                md += "### Tool Prices\n\n"
                md += "| Tool | Price (sats) | Category |\n"
                md += "|------|-------------|----------|\n"
                for tool in tools {
                    md += "| \(tool.toolName) | \(tool.priceSats) | \(tool.category) |\n"
                }
                md += "\n"
            }

            if let pipeline = proposal.pipeline, !pipeline.isEmpty {
                md += "### Constraint Pipeline\n\n"
                for (i, step) in pipeline.enumerated() {
                    md += "**Step \(i + 1): \(step.type)**\n"
                    for (key, value) in step.params.sorted(by: { $0.key < $1.key }) {
                        md += "- \(key): \(value)\n"
                    }
                    md += "\n"
                }
            }
        }

        // Revenue projections
        if let proj = revenueProjections {
            md += "## Revenue Projections\n\n"
            if let tam = proj.tam { md += "- TAM: \(tam)\n" }
            if let sam = proj.sam { md += "- SAM: \(sam)\n" }
            if let som = proj.som { md += "- SOM: \(som)\n" }
            for rp in proj.projections {
                md += "- **\(rp.scenario)**: \(rp.revenueSats.formatted()) sats/mo "
                md += "(\(rp.monthlyUsers) users, \(rp.callsPerUserPerMonth) calls/user)\n"
            }
            md += "\n"
        }

        // Peer review
        if let review = secondOpinionText, !review.isEmpty {
            md += "## Peer Review\n\n"
            md += review
            md += "\n\n"
        }

        // Interview highlights (assistant messages only, abbreviated)
        let assistantMsgs = messages.filter { $0.role == .assistant }
        if !assistantMsgs.isEmpty {
            md += "## Interview Highlights\n\n"
            for msg in assistantMsgs.prefix(10) {
                let preview = String(msg.content.prefix(300))
                let stage = msg.stageNumber.map { "Stage \($0)" } ?? ""
                if !stage.isEmpty { md += "**\(stage)**\n\n" }
                md += "> \(preview.replacingOccurrences(of: "\n", with: "\n> "))\n\n"
            }
            if assistantMsgs.count > 10 {
                md += "*(\(assistantMsgs.count - 10) more messages in full export)*\n\n"
            }
        }

        md += "---\n\n"
        md += "*Exported from [Pricing Studio](https://github.com/lonniev/tollbooth-pricing-studio) "
        md += "— part of the [DPYC](https://github.com/lonniev/dpyc-community) ecosystem.*\n"

        return md
    }
}
