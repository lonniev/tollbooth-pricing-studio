import Foundation

struct AssistantMessage: Identifiable {
    let id = UUID()
    let role: Role
    var content: String
    let timestamp: Date
    var isStreaming: Bool
    var stageNumber: Int?

    enum Role: String, Sendable {
        case user
        case assistant
    }

    init(role: Role, content: String, timestamp: Date = Date(), isStreaming: Bool = false, stageNumber: Int? = nil) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.stageNumber = stageNumber
    }
}
