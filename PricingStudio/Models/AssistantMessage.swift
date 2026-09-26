import Foundation

struct AssistantMessage: Identifiable {
    let id = UUID()
    let role: Role
    var content: String
    let timestamp: Date
    var isStreaming: Bool
    var stageNumber: Int?
    /// OpenRouter model slug that produced this assistant reply. Nil for user
    /// turns and for messages saved before the OpenRouter cutover. Captured at
    /// send time so a later Settings change never relabels old answers.
    var modelSlug: String?

    enum Role: String, Sendable {
        case user
        case assistant
    }

    init(
        role: Role,
        content: String,
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        stageNumber: Int? = nil,
        modelSlug: String? = nil
    ) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.stageNumber = stageNumber
        self.modelSlug = modelSlug
    }
}
