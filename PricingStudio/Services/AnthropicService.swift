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

    // MARK: - Consultant Local Tools

    /// In-process tools available to every consultant persona.
    /// Mutations land in `Campaign.consultantNotes` via the registered executor.
    nonisolated(unsafe) static let consultantTools: [[String: Any]] = [
        [
            "name": "update_summary",
            "description": "Replace your one-paragraph 'what I have concluded so far' summary, displayed on your business card and surfaced to peers in their briefings. Call after each substantive turn so peers see fresh context.",
            "input_schema": [
                "type": "object",
                "properties": ["summary": ["type": "string", "description": "One paragraph in your own voice — max ~3 sentences."]],
                "required": ["summary"]
            ] as [String: Any]
        ],
        [
            "name": "propose_delta",
            "description": "Record one structured edit you want made to the working pricing model. The Managing Partner (Hayek) will weigh all proposed deltas during synthesis. Each call appends one delta — call multiple times for multiple edits.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "kind": [
                        "type": "string",
                        "enum": ["tool_price", "add_constraint", "remove_constraint", "projection_assumption"],
                        "description": "tool_price (set a per-tool sat price), add_constraint (push a pipeline step), remove_constraint (drop one by index), projection_assumption (set a revenue-projection input)."
                    ],
                    "payload": [
                        "type": "object",
                        "description": "Kind-specific fields. tool_price: {tool_name, sats}. add_constraint: {type, params_json}. remove_constraint: {index}. projection_assumption: {scenario, field, value}.",
                        "additionalProperties": ["type": "string"] as [String: Any]
                    ],
                    "rationale": ["type": "string", "description": "One-sentence reason — why does this delta follow from your analysis?"]
                ],
                "required": ["kind", "payload", "rationale"]
            ] as [String: Any]
        ],
        [
            "name": "flag_open_question",
            "description": "Record a question you cannot answer without operator input. Surfaces as a badge on your business card so the user knows they owe you a decision before you can finalize.",
            "input_schema": [
                "type": "object",
                "properties": ["question": ["type": "string", "description": "One question, phrased so the operator can answer it succinctly."]],
                "required": ["question"]
            ] as [String: Any]
        ],
        [
            "name": "flag_concern",
            "description": "Record a critique of a peer consultant's analysis. Surfaces when the user next visits that peer. Use sparingly — only when a peer's premise materially affects your own analysis.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "peer_stage": ["type": "integer", "description": "Stage number 1–6 of the peer you are critiquing (1=Menger, 2=Wieser, 3=Böhm-Bawerk, 4=Wicksteed, 5=Mises, 6=Hayek)."],
                    "concern": ["type": "string", "description": "What you would tell that peer if they were in the room."]
                ],
                "required": ["peer_stage", "concern"]
            ] as [String: Any]
        ],
        [
            "name": "read_peer_notes",
            "description": "Read a peer consultant's current note (summary + proposed deltas + open questions). Returns JSON. Call before forming an opinion that depends on what a peer concluded.",
            "input_schema": [
                "type": "object",
                "properties": ["stage": ["type": "integer", "description": "Stage number 1–6 of the peer whose note you want to read."]],
                "required": ["stage"]
            ] as [String: Any]
        ],
        [
            "name": "read_working_model",
            "description": "Read the current published pricing proposal (tool prices, pipeline, projections) as JSON. Returns the most recent merged state — empty if Hayek has not yet synthesized.",
            "input_schema": ["type": "object", "properties": [:] as [String: Any]]
        ],
    ]

    /// Tools available only to Hayek (Managing Partner, stage 6).
    nonisolated(unsafe) static let hayekTools: [[String: Any]] = [
        [
            "name": "merge_proposal",
            "description": "Synthesize all consultants' notes and deltas into the deployable PricingProposal. Overwrites the current proposal. Only Hayek may call this — it is the act of synthesis.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "proposal_json": [
                        "type": "string",
                        "description": "A JSON object matching PricingProposal: {tool_prices: [{tool_id, tool_name, price_sats, ...}], pipeline: [{type, params, ...}], projections: {projections: [{scenario, monthly_users, calls_per_user_per_month, revenue_sats, revenue_usd}, ...], tool_count, avg_price_sats}}."
                    ]
                ],
                "required": ["proposal_json"]
            ] as [String: Any]
        ],
    ]

    /// Callback the view model registers per session to handle consultant + Hayek tool calls.
    /// Closes over the active campaign and computes the active stage at call time.
    /// Returns (chatBubbleMarkdown, machineResultForClaude).
    nonisolated(unsafe) static var executeConsultantTool: ((String, [String: Any]) async -> (bubble: String, result: String))?

    // MARK: - Tool Executor

    /// Callback to execute MCP tool calls (Oracle + operator). Set by ContentView.
    /// Parameters: (toolName, input) → result string.
    nonisolated(unsafe) static var executeOracleTool: ((String, [String: Any]) async -> String)?

    /// Additional operator-specific tool definitions, set per-session.
    /// These are appended to `oracleTools` when `includeTools` is true.
    nonisolated(unsafe) static var operatorTools: [[String: Any]] = []

    /// Callback to execute operator MCP tool calls (different endpoint from Oracle).
    nonisolated(unsafe) static var executeOperatorTool: ((String, [String: Any]) async -> String)?

    /// Combined tool list: Oracle + operator + consultant tools.
    /// Consultant tools (and Hayek's merge_proposal) are only included when the
    /// view model has registered an `executeConsultantTool` callback — i.e.,
    /// when the user is inside the Pricing Consultant flow.
    static var allTools: [[String: Any]] {
        var tools = oracleTools + operatorTools
        if executeConsultantTool != nil {
            tools += consultantTools + hayekTools
        }
        return tools
    }

    /// True if `name` is one of our consultant or Hayek-only local tools.
    private static func isConsultantTool(_ name: String) -> Bool {
        consultantTools.contains { ($0["name"] as? String) == name } ||
        hayekTools.contains { ($0["name"] as? String) == name }
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

    /// Maximum number of tool-use rounds in a single advisor turn.
    /// At cap, force a no-tools final round so Claude must speak.
    private static let maxToolIterations = 6

    private nonisolated func streamWithToolUse(
        messages: [[String: String]],
        systemPrompt: String,
        apiKey: String,
        maxTokens: Int,
        continuation: AsyncStream<String>.Continuation
    ) async {
        // Seed the running message history with the caller's turn(s).
        // We append assistant tool_use + user tool_result blocks each
        // iteration so Claude can chain multiple tool calls before
        // emitting text.
        var apiMessages: [[String: Any]] = messages.map { msg in
            ["role": msg["role"] ?? "user", "content": msg["content"] ?? ""]
        }

        var iteration = 0
        var lastResult: RequestResult = RequestResult()

        while iteration < Self.maxToolIterations {
            iteration += 1

            // Pass a snapshot so the `sending` parameter is region-isolated.
            let snapshot: [[String: Any]] = apiMessages
            lastResult = await sendRequest(
                messages: snapshot,
                systemPrompt: systemPrompt,
                apiKey: apiKey,
                maxTokens: maxTokens,
                includeTools: true,
                continuation: continuation
            )

            // No tool_use → Claude is done with tools this turn. Whatever
            // text was streamed already appears in the chat. Done.
            guard let toolUse = lastResult.toolUse else {
                continuation.finish()
                return
            }

            // Execute the tool, append assistant tool_use + user tool_result
            // to apiMessages, and loop for Claude's next move.
            let isOracleTool = Self.oracleTools.contains { ($0["name"] as? String) == toolUse.name }
            let isConsultantTool = Self.isConsultantTool(toolUse.name)
            let label = isOracleTool ? "Oracle" : (isConsultantTool ? "Consultant" : "Operator")

            await MainActor.run {
                TrafficLogger.shared.log(.outbound, label: "\(label) Tool",
                                         detail: "Claude called: \(toolUse.name) (round \(iteration))")
            }

            // Consultant tools render their own inline bubble after execution
            // (showing what was actually proposed). Oracle/Operator tools get
            // the existing "*Consulting X…*" placeholder while we wait.
            if !isConsultantTool {
                continuation.yield("\n\n*Consulting \(label)…*\n\n")
            }

            let mcpToolName = Self.toolNameMap[toolUse.name] ?? toolUse.name
            let toolInput = toolUse.input
            let inputPreview = String(toolUse.inputJSON.prefix(300))
            await MainActor.run {
                TrafficLogger.shared.log(.outbound, label: "\(label) Executor START",
                                         detail: "round=\(iteration) name=\(toolUse.name) mcpName=\(mcpToolName) input=\(inputPreview)")
            }
            let executorStart = Date()
            var toolResult: String
            if isOracleTool, let executor = Self.executeOracleTool {
                toolResult = await executor(mcpToolName, toolInput)
            } else if isConsultantTool, let executor = Self.executeConsultantTool {
                let outcome = await executor(toolUse.name, toolInput)
                if !outcome.bubble.isEmpty {
                    continuation.yield(outcome.bubble)
                }
                toolResult = outcome.result
            } else if !isOracleTool, !isConsultantTool, let executor = Self.executeOperatorTool {
                toolResult = await executor(toolUse.name, toolInput)
            } else {
                toolResult = "\(label) tool executor not configured."
            }
            let elapsedMs = Int(Date().timeIntervalSince(executorStart) * 1000)
            await MainActor.run {
                TrafficLogger.shared.log(.inbound, label: "\(label) Executor END",
                                         detail: "round=\(iteration) elapsed=\(elapsedMs)ms result_len=\(toolResult.count) preview=\(String(toolResult.prefix(300)))")
            }

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

            let inputObj = toolInputJSON.data(using: .utf8).flatMap {
                try? JSONSerialization.jsonObject(with: $0)
            } ?? [:]
            let assistantContent: [[String: Any]] = [
                ["type": "tool_use", "id": toolId, "name": toolName, "input": inputObj]
            ]
            let toolResultContent: [[String: Any]] = [
                ["type": "tool_result", "tool_use_id": toolId, "content": toolResult]
            ]
            apiMessages.append(["role": "assistant", "content": assistantContent])
            apiMessages.append(["role": "user", "content": toolResultContent])
        }

        // Cap fired and we still don't have a textual answer. Force a
        // final no-tools round with a nudge so the user gets something
        // back instead of a silent placeholder.
        await MainActor.run {
            TrafficLogger.shared.log(.outbound, label: "Tool Loop Cap",
                                     detail: "Hit \(Self.maxToolIterations)-round cap; forcing textual summary.")
        }
        let nudge = "You've used \(Self.maxToolIterations) tool calls this turn. Stop calling tools and either summarize what you found so far or ask the operator the next focused question."
        apiMessages.append(["role": "user", "content": nudge])
        let snapshot: [[String: Any]] = apiMessages
        _ = await sendRequest(
            messages: snapshot,
            systemPrompt: systemPrompt,
            apiKey: apiKey,
            maxTokens: maxTokens,
            includeTools: false,
            continuation: continuation
        )
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
        var stopReason: String?  // end_turn, max_tokens, tool_use, stop_sequence, etc.
        var contentBlockCount: Int = 0  // number of content blocks the response carried
        var blockTypes: [String] = []  // type of each block in arrival order
    }

    // MARK: - Core Request

    private nonisolated func sendRequest(
        messages: [[String: Any]],
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

        // Surface what we actually sent: system prompt head, last user
        // message, declared tools. The wire payload itself isn't useful;
        // what matters when debugging the advisor is "what did we ask
        // Claude to do and what tools did we tell it about."
        let systemHead = String(systemPrompt.prefix(800))
        let lastUserSnippet: String = {
            for msg in messages.reversed() where (msg["role"] as? String) == "user" {
                if let s = msg["content"] as? String { return String(s.prefix(400)) }
                if let blocks = msg["content"] as? [[String: Any]] {
                    let texts = blocks.compactMap { ($0["content"] as? String) ?? ($0["text"] as? String) }
                    return String(texts.joined(separator: " | ").prefix(400))
                }
            }
            return "<no user message>"
        }()
        let toolNames: String = includeTools
            ? Self.allTools.compactMap { $0["name"] as? String }.joined(separator: ", ")
            : "(none)"
        let outBody = """
        model=\(Self.model)
        messages=\(messages.count) turns
        tools=\(toolNames)
        system[head]:
        \(systemHead)
        last_user:
        \(lastUserSnippet)
        """
        await MainActor.run {
            TrafficLogger.shared.logHTTP(
                label: "Anthropic Messages",
                method: "POST",
                url: Self.apiURL.absoluteString,
                requestBody: outBody
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
                    result.contentBlockCount += 1
                    result.blockTypes.append(blockType)
                    if blockType == "tool_use" {
                        currentToolId = block["id"] as? String ?? ""
                        currentToolName = block["name"] as? String ?? ""
                        currentToolInputJSON = ""
                    }
                } else if type == "message_delta",
                          let delta = event["delta"] as? [String: Any] {
                    if let reason = delta["stop_reason"] as? String {
                        result.stopReason = reason
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

            // Make "Stream Complete" actually informative: text head and
            // tool_use summary. Empty text + a tool_use is the common
            // case for the advisor's first turn.
            let textHead = result.textContent.isEmpty
                ? "<no text content>"
                : String(result.textContent.prefix(800))
            let toolSummary: String
            if let t = result.toolUse {
                let inputPreview = String(t.inputJSON.prefix(300))
                toolSummary = "tool_use: name=\(t.name) id=\(t.id) input=\(inputPreview)"
            } else {
                toolSummary = "tool_use: (none)"
            }
            let blocksSummary: String
            if result.blockTypes.isEmpty {
                blocksSummary = "(zero content blocks)"
            } else {
                let counts = Dictionary(grouping: result.blockTypes, by: { $0 })
                    .mapValues { $0.count }
                    .map { "\($0.key)=\($0.value)" }
                    .sorted()
                    .joined(separator: ", ")
                blocksSummary = "\(result.contentBlockCount) blocks: \(counts)"
            }
            let inBody = """
            stop_reason: \(result.stopReason ?? "<unknown>")
            blocks: \(blocksSummary)
            \(toolSummary)
            text[head]:
            \(textHead)
            """
            await MainActor.run {
                TrafficLogger.shared.logHTTP(
                    label: "Anthropic Stream Complete",
                    method: "POST",
                    url: Self.apiURL.absoluteString,
                    statusCode: 200,
                    responseBody: inBody
                )
            }
        } catch {
            logger.error("Anthropic streaming error: \(error.localizedDescription)")
            continuation.yield("[Error: \(error.localizedDescription)]")
        }

        return result
    }
}
