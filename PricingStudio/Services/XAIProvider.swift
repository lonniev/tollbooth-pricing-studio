import Foundation
import OSLog

private let logger = Logger(subsystem: "com.tollbooth.dpyc.PricingStudio", category: "XAI")

/// xAI Grok provider using the OpenAI-compatible chat completions API.
struct XAIProvider: LLMProvider, Sendable {

    private static let apiURL = URL(string: "https://api.x.ai/v1/chat/completions")!
    private static let model = "grok-3"

    private let apiKey: String

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
                await self.performStream(
                    messages: messages,
                    systemPrompt: systemPrompt,
                    maxTokens: maxTokens,
                    continuation: continuation
                )
            }
        }
    }

    private func performStream(
        messages: [[String: String]],
        systemPrompt: String,
        maxTokens: Int,
        continuation: AsyncStream<String>.Continuation
    ) async {
        var request = URLRequest(url: Self.apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // Build OpenAI-compatible messages array with system message first
        var apiMessages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]
        apiMessages.append(contentsOf: messages)

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": maxTokens,
            "stream": true,
            "messages": apiMessages,
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            continuation.yield("[Error: Failed to serialize request]")
            continuation.finish()
            return
        }
        request.httpBody = bodyData

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let httpResponse = response as? HTTPURLResponse

            guard let statusCode = httpResponse?.statusCode, statusCode == 200 else {
                let code = httpResponse?.statusCode ?? 0
                var errorBody = ""
                for try await line in bytes.lines {
                    errorBody += line
                    if errorBody.count > 500 { break }
                }
                logger.error("xAI HTTP \(code): \(errorBody.prefix(200))")
                continuation.yield("[Error: HTTP \(code) — \(errorBody.prefix(200))]")
                continuation.finish()
                return
            }

            // Parse SSE stream (OpenAI-compatible format)
            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))

                if payload == "[DONE]" { break }

                guard let data = payload.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = event["choices"] as? [[String: Any]],
                      let first = choices.first,
                      let delta = first["delta"] as? [String: Any],
                      let content = delta["content"] as? String else { continue }

                continuation.yield(content)

                // Check for finish_reason
                if let finishReason = first["finish_reason"] as? String, finishReason == "stop" {
                    break
                }
            }

            logger.info("xAI stream complete")
        } catch {
            logger.error("xAI streaming error: \(error.localizedDescription)")
            continuation.yield("[Error: \(error.localizedDescription)]")
        }

        continuation.finish()
    }
}
