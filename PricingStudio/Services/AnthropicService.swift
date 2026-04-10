import Foundation
import OSLog

private let logger = Logger(subsystem: "com.tollbooth.dpyc.PricingStudio", category: "Anthropic")


@preconcurrency
final class AnthropicService: @unchecked Sendable {

    private static let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-sonnet-4-6"
    private static let maxTokens = 2048

    /// Map API error responses to clear, actionable user messages.
    private static func friendlyErrorMessage(statusCode: Int, body: String) -> String {
        let lower = body.lowercased()
        switch statusCode {
        case 400 where lower.contains("credit balance"):
            return "[AI provider credits exhausted. Add credits at console.anthropic.com before continuing.]"
        case 401:
            return "[AI provider API key is invalid or expired. Check your Anthropic key in Settings.]"
        case 429:
            return "[AI provider rate limit reached. Wait a moment and try again.]"
        case 529, 503:
            return "[AI provider is temporarily overloaded. Try again in a few seconds.]"
        default:
            return "[AI provider error (HTTP \(statusCode)). Check Settings or try again later.]"
        }
    }

    // MARK: - Oracle Tool Definitions

    nonisolated(unsafe) static let oracleTools: [[String: Any]] = [
        [
            "name": "oracle_how_to_join",
            "description": "Get step-by-step onboarding instructions for joining the DPYC Honor Chain. Covers all five tiers: Citizen, Advocate, Operator, Authority, First Curator.",
            "input_schema": ["type": "object", "properties": [:] as [String: Any]]
        ],
        [
            "name": "oracle_about",
            "description": "Get a description of the DPYC ecosystem — what it is, how it works, why it exists.",
            "input_schema": ["type": "object", "properties": [:] as [String: Any]]
        ],
        [
            "name": "oracle_economic_model",
            "description": "Get the DPYC economic model — how money flows, certification fees, Lightning invoices, tranche-based credits.",
            "input_schema": ["type": "object", "properties": [:] as [String: Any]]
        ],
        [
            "name": "oracle_get_rulebook",
            "description": "Get the DPYC governance rules and principles.",
            "input_schema": ["type": "object", "properties": [:] as [String: Any]]
        ],
        [
            "name": "oracle_lookup_member",
            "description": "Look up a DPYC member by their Nostr npub. Returns role, display name, services, and authority chain.",
            "input_schema": [
                "type": "object",
                "properties": ["npub": ["type": "string", "description": "The Nostr npub to look up"]],
                "required": ["npub"]
            ] as [String: Any]
        ],
        [
            "name": "oracle_network_advisory",
            "description": "Get current network advisories — recent changes, upgrades, and actions operators should take.",
            "input_schema": ["type": "object", "properties": [:] as [String: Any]]
        ],
    ]

    /// Map Oracle tool names to MCP tool names
    static let toolNameMap: [String: String] = [
        "oracle_how_to_join": "how_to_join",
        "oracle_about": "about",
        "oracle_economic_model": "economic_model",
        "oracle_get_rulebook": "get_rulebook",
        "oracle_lookup_member": "lookup_member",
        "oracle_network_advisory": "network_advisory",
    ]

    // MARK: - Tool Executor

    /// Callback to execute MCP tool calls (Oracle + operator). Set by ContentView.
    /// Parameters: (toolName, input) → result string.
    nonisolated(unsafe) static var executeOracleTool: ((String, [String: Any]) async -> String)?

    /// Additional operator-specific tool definitions, set per-session.
    /// These are appended to `oracleTools` when `includeTools` is true.
    nonisolated(unsafe) static var operatorTools: [[String: Any]] = []

    /// Callback to execute operator MCP tool calls (different endpoint from Oracle).
    nonisolated(unsafe) static var executeOperatorTool: ((String, [String: Any]) async -> String)?

    /// Combined tool list: Oracle + operator tools.
    static var allTools: [[String: Any]] {
        oracleTools + operatorTools
    }

    // MARK: - Send Message (with tool use)

    /// Send a message and stream the response tokens back.
    /// Supports Oracle tool use — if Claude requests a tool call, executes it
    /// and feeds the result back for a final response.
    func sendMessage(
        messages: [[String: String]],
        systemPrompt: String,
        apiKey: String,
        maxTokens: Int = 2048,
        includeTools: Bool = true
    ) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                if includeTools {
                    await self.streamWithToolUse(
                        messages: messages,
                        systemPrompt: systemPrompt,
                        apiKey: apiKey,
                        maxTokens: maxTokens,
                        continuation: continuation
                    )
                } else {
                    let apiMessages = messages.map { msg in
                        ["role": msg["role"] ?? "user", "content": msg["content"] ?? ""] as [String: Any]
                    }
                    _ = await self.sendRequest(
                        messages: apiMessages,
                        systemPrompt: systemPrompt,
                        apiKey: apiKey,
                        maxTokens: maxTokens,
                        includeTools: false,
                        continuation: continuation
                    )
                    continuation.finish()
                }
            }
        }
    }

    private nonisolated func streamWithToolUse(
        messages: [[String: String]],
        systemPrompt: String,
        apiKey: String,
        maxTokens: Int,
        continuation: AsyncStream<String>.Continuation
    ) async {
        let rawMessages = messages  // capture for reuse

        // Convert simple string messages to content-block format for tool use
        func buildApiMessages() -> [[String: Any]] {
            rawMessages.map { msg in
                ["role": msg["role"] ?? "user", "content": msg["content"] ?? ""]
            }
        }

        // First request — may return text or tool_use
        let result = await sendRequest(
            messages: buildApiMessages(),
            systemPrompt: systemPrompt,
            apiKey: apiKey,
            maxTokens: maxTokens,
            includeTools: true,
            continuation: continuation
        )

        // If Claude requested tool use, execute and continue
        if let toolUse = result.toolUse {
            let isOracleTool = Self.oracleTools.contains { ($0["name"] as? String) == toolUse.name }
            let label = isOracleTool ? "Oracle" : "Operator"

            await MainActor.run {
                TrafficLogger.shared.log(.outbound, label: "\(label) Tool",
                                         detail: "Claude called: \(toolUse.name)")
            }

            continuation.yield("\n\n*Consulting \(label)…*\n\n")

            let mcpToolName = Self.toolNameMap[toolUse.name] ?? toolUse.name
            let toolInput = toolUse.input
            var toolResult: String
            if isOracleTool, let executor = Self.executeOracleTool {
                toolResult = await executor(mcpToolName, toolInput)
            } else if !isOracleTool, let executor = Self.executeOperatorTool {
                toolResult = await executor(toolUse.name, toolInput)
            } else {
                toolResult = "\(label) tool executor not configured."
            }

            // Guard against empty or error results that would confuse Claude
            if toolResult.isEmpty {
                toolResult = "Tool returned no data."
            }

            let toolId = toolUse.id
            let toolName = toolUse.name
            let toolInputJSON = toolUse.inputJSON

            await MainActor.run {
                TrafficLogger.shared.log(.inbound, label: "\(label) Tool",
                                         detail: "\(toolName) → \(String(toolResult.prefix(100)))")
            }

            // Build follow-up messages with tool result
            let inputObj = toolInputJSON.data(using: .utf8).flatMap {
                try? JSONSerialization.jsonObject(with: $0)
            } ?? [:]
            let assistantContent: [[String: Any]] = [
                ["type": "tool_use", "id": toolId, "name": toolName, "input": inputObj]
            ]
            let toolResultContent: [[String: Any]] = [
                ["type": "tool_result", "tool_use_id": toolId, "content": toolResult]
            ]
            var followUp = buildApiMessages()
            followUp.append(["role": "assistant", "content": assistantContent])
            followUp.append(["role": "user", "content": toolResultContent])

            // Second request — Claude incorporates tool result
            _ = await sendRequest(
                messages: followUp,
                systemPrompt: systemPrompt,
                apiKey: apiKey,
                maxTokens: maxTokens,
                includeTools: false,
                continuation: continuation
            )
        }

        continuation.finish()
    }

    // MARK: - Tool Use Types

    struct ToolUseCall: @unchecked Sendable {
        let id: String
        let name: String
        let input: [String: Any]
        let inputJSON: String  // Serialized for sendable transport
    }

    struct RequestResult: @unchecked Sendable {
        var textContent: String = ""
        var toolUse: ToolUseCall?
        var contentBlocks: Any?  // JSON-serializable content blocks
        var contentBlocksJSON: String = "[]"
    }

    // MARK: - Core Request

    private nonisolated func sendRequest(
        messages: sending [[String: Any]],
        systemPrompt: String,
        apiKey: String,
        maxTokens: Int,
        includeTools: Bool,
        continuation: AsyncStream<String>.Continuation
    ) async -> RequestResult {
        var request = URLRequest(url: Self.apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": Self.model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": systemPrompt,
            "messages": messages,
        ]
        if includeTools {
            body["tools"] = Self.allTools
        }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            continuation.yield("[Error: Failed to serialize request]")
            return RequestResult()
        }
        request.httpBody = bodyData

        await MainActor.run {
            TrafficLogger.shared.logHTTP(
                label: "Anthropic Messages",
                method: "POST",
                url: Self.apiURL.absoluteString,
                requestBody: "model=\(Self.model), messages=\(messages.count), tools=\(includeTools)"
            )
        }

        var result = RequestResult()
        var currentToolId = ""
        var currentToolName = ""
        var currentToolInputJSON = ""

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
                let userMessage = Self.friendlyErrorMessage(statusCode: code, body: errorBody)
                continuation.yield(userMessage)
                return result
            }

            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))
                if payload == "[DONE]" { break }

                guard let data = payload.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = event["type"] as? String else { continue }

                if type == "content_block_start",
                   let block = event["content_block"] as? [String: Any],
                   let blockType = block["type"] as? String {
                    if blockType == "tool_use" {
                        currentToolId = block["id"] as? String ?? ""
                        currentToolName = block["name"] as? String ?? ""
                        currentToolInputJSON = ""
                    }
                } else if type == "content_block_delta",
                          let delta = event["delta"] as? [String: Any] {
                    if let text = delta["text"] as? String {
                        // Text content — stream to UI
                        continuation.yield(text)
                        result.textContent += text
                    } else if let partialJson = delta["partial_json"] as? String {
                        // Tool input accumulating
                        currentToolInputJSON += partialJson
                    }
                } else if type == "content_block_stop" {
                    if !currentToolName.isEmpty {
                        // Tool use block complete
                        let input = (try? JSONSerialization.jsonObject(
                            with: (currentToolInputJSON.isEmpty ? "{}" : currentToolInputJSON).data(using: .utf8)!
                        ) as? [String: Any]) ?? [:]

                        result.toolUse = ToolUseCall(
                            id: currentToolId,
                            name: currentToolName,
                            input: input,
                            inputJSON: currentToolInputJSON.isEmpty ? "{}" : currentToolInputJSON
                        )
                        currentToolName = ""
                    }
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

        return result
    }
}
