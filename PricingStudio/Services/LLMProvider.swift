import Foundation

/// Abstraction over streaming LLM providers (xAI Grok, Anthropic Claude).
protocol LLMProvider: Sendable {
    /// Stream a chat completion. Returns tokens as they arrive.
    func streamCompletion(
        messages: [[String: String]],
        systemPrompt: String,
        maxTokens: Int
    ) -> AsyncStream<String>
}
