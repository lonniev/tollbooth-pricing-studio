import Foundation
import OSLog

private let logger = Logger(subsystem: "com.tollbooth.dpyc.PricingStudio", category: "Anthropic")

actor AnthropicService {

    private static let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-sonnet-4-6"
    private static let maxTokens = 2048

    /// Send a message and stream the response tokens back.
    func sendMessage(
        messages: [[String: String]],
        systemPrompt: String,
        apiKey: String,
        maxTokens: Int = 2048
    ) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                await self.streamRequest(
                    messages: messages,
                    systemPrompt: systemPrompt,
                    apiKey: apiKey,
                    maxTokens: maxTokens,
                    continuation: continuation
                )
            }
        }
    }

    private func streamRequest(
        messages: [[String: String]],
        systemPrompt: String,
        apiKey: String,
        maxTokens: Int = 2048,
        continuation: AsyncStream<String>.Continuation
    ) async {
        var request = URLRequest(url: Self.apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": systemPrompt,
            "messages": messages,
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            continuation.yield("[Error: Failed to serialize request]")
            continuation.finish()
            return
        }
        request.httpBody = bodyData

        await MainActor.run {
            TrafficLogger.shared.logHTTP(
                label: "Anthropic Messages",
                method: "POST",
                url: Self.apiURL.absoluteString,
                requestBody: "model=\(Self.model), messages=\(messages.count)"
            )
        }

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
                await MainActor.run {
                    TrafficLogger.shared.logHTTP(
                        label: "Anthropic Error",
                        method: "POST",
                        url: Self.apiURL.absoluteString,
                        statusCode: code,
                        responseBody: errorBody,
                        error: "HTTP \(code)"
                    )
                }
                continuation.yield("[Error: HTTP \(code) — \(errorBody.prefix(200))]")
                continuation.finish()
                return
            }

            // Parse SSE stream
            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))

                if payload == "[DONE]" { break }

                guard let data = payload.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = event["type"] as? String else { continue }

                if type == "content_block_delta",
                   let delta = event["delta"] as? [String: Any],
                   let text = delta["text"] as? String {
                    continuation.yield(text)
                } else if type == "message_stop" {
                    break
                } else if type == "error",
                          let error = event["error"] as? [String: Any],
                          let msg = error["message"] as? String {
                    continuation.yield("\n[Error: \(msg)]")
                    break
                }
            }

            await MainActor.run {
                TrafficLogger.shared.logHTTP(
                    label: "Anthropic Stream Complete",
                    method: "POST",
                    url: Self.apiURL.absoluteString,
                    statusCode: 200
                )
            }
        } catch {
            logger.error("Anthropic streaming error: \(error.localizedDescription)")
            continuation.yield("[Error: \(error.localizedDescription)]")
        }

        continuation.finish()
    }
}
