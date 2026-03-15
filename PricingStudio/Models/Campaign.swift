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

    // MARK: - Message Serialization

    var messages: [AssistantMessage] {
        get { Campaign.decode(messagesJSON) }
        set {
            messagesJSON = Campaign.encode(newValue)
            updatedAt = Date()
        }
    }

    private static func encode(_ messages: [AssistantMessage]) -> Data {
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

    private static func decode(_ data: Data) -> [AssistantMessage] {
        guard let dicts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
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
}
