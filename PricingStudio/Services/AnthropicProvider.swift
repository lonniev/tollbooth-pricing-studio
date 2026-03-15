import Foundation

/// Wraps the existing AnthropicService to conform to the LLMProvider protocol.
struct AnthropicProvider: LLMProvider, Sendable {

    private let apiKey: String
    private let service = AnthropicService()

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func streamCompletion(
        messages: [[String: String]],
        systemPrompt: String,
        maxTokens: Int
    ) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                let stream = await service.sendMessage(
                    messages: messages,
                    systemPrompt: systemPrompt,
                    apiKey: apiKey,
                    maxTokens: maxTokens
                )
                for await token in stream {
                    continuation.yield(token)
                }
                continuation.finish()
            }
        }
    }
}
