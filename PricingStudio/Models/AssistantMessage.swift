import Foundation

struct AssistantMessage: Identifiable {
    let id = UUID()
    let role: Role
    var content: String
    let timestamp: Date
    var isStreaming: Bool

    enum Role: String, Sendable {
        case user
        case assistant
    }

    init(role: Role, content: String, isStreaming: Bool = false) {
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.isStreaming = isStreaming
    }
}
