import Foundation
import MCP

actor MCPService {

    enum ConnectionStep: String, Sendable {
        case resolvingOracle = "Resolving Oracle endpoint..."
        case lookingUpOperator = "Looking up operator..."
        case authenticating = "Authenticating with Horizon..."
        case connectingToOperator = "Connecting to operator MCP..."
        case fetchingPricing = "Fetching pricing model..."
        case done = "Done"
    }

    func lookupOperator(npub: String, bearerToken: String, onStep: @Sendable (ConnectionStep) -> Void) async throws -> MemberRecord {
        onStep(.resolvingOracle)
        let oracleURL = try await RegistryService.resolveOracleURL(forOperator: npub)

        onStep(.lookingUpOperator)
        return try await callOracleLookup(oracleURL: oracleURL, npub: npub, bearerToken: bearerToken)
    }

    func resolveOracleURL(forOperator npub: String) async throws -> URL {
        try await RegistryService.resolveOracleURL(forOperator: npub)
    }

    func fetchPricingModel(
        endpointURL: URL,
        bearerToken: String,
        onStep: @Sendable (ConnectionStep) -> Void
    ) async throws -> PricingModelResponse {
        onStep(.connectingToOperator)

        onStep(.fetchingPricing)
        let result = try await synthesizePricingModel(endpointURL: endpointURL, bearerToken: bearerToken)

        onStep(.done)
        return result
    }

    // MARK: - Oracle Lookup

    private func callOracleLookup(oracleURL: URL, npub: String, bearerToken: String) async throws -> MemberRecord {
        await traffic(.outbound, label: "Oracle Connect", detail: "SSE → \(oracleURL.absoluteString) (Bearer auth)")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = HTTPClientTransport(
            endpoint: oracleURL,
            streaming: true,
            sseInitializationTimeout: 30,
            requestModifier: { request in
                var req = request
                req.addValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
                return req
            }
        )
        defer { Task { await client.disconnect() } }
        do {
            try await client.connect(transport: transport)
            await traffic(.inbound, label: "Oracle Connected", detail: "SSE session established to \(oracleURL.absoluteString)")
        } catch {
            await traffic(.error, label: "Oracle Connect Failed", detail: "URL: \(oracleURL.absoluteString)\nError: \(String(describing: error))\nType: \(type(of: error))")
            throw error
        }

        // Find the lookup_member tool
        await traffic(.outbound, label: "Oracle listTools", detail: "Discovering available tools")
        let allTools = try await listAllTools(client: client)
        let toolNames = allTools.map(\.name).joined(separator: ", ")
        await traffic(.inbound, label: "Oracle listTools → \(allTools.count) tools", detail: toolNames)

        guard let lookupTool = allTools.first(where: { $0.name.contains("lookup_member") }) else {
            await traffic(.error, label: "Oracle: no lookup_member tool", detail: "Available: \(toolNames)")
            throw MCPError.toolCallFailed("No lookup_member tool found on Oracle")
        }

        await traffic(.outbound, label: "callTool: \(lookupTool.name)", detail: "{\"npub\": \"\(npub)\"}")
        let (content, isError) = try await client.callTool(
            name: lookupTool.name,
            arguments: ["npub": .string(npub)]
        )

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            await traffic(.error, label: "Oracle lookup_member error", detail: errorText)
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first,
              let data = text.data(using: .utf8) else {
            await traffic(.error, label: "Oracle lookup_member", detail: "No text content in response")
            throw MCPError.invalidResponse
        }

        let preview = String(text.prefix(500))
        await traffic(.inbound, label: "Oracle lookup_member response", detail: preview)

        // Oracle may wrap response in {"result": <MemberRecord or String>}
        // or return MemberRecord directly. Try both.
        do {
            let wrapper = try JSONDecoder().decode(OracleLookupResponse.self, from: data)
            switch wrapper.result {
            case .member(let record):
                return record
            case .message(let msg):
                await traffic(.error, label: "Oracle: member not found", detail: msg)
                throw MCPError.toolCallFailed(msg)
            }
        } catch let mcpError as MCPError {
            throw mcpError
        } catch {
            // No wrapper — try decoding MemberRecord directly
            do {
                let record = try JSONDecoder().decode(MemberRecord.self, from: data)
                return record
            } catch {
                await traffic(.error, label: "Oracle: unexpected response", detail: "Raw: \(preview)\nDecode error: \(error.localizedDescription)")
                throw MCPError.toolCallFailed("Operator not found in DPYC registry. Oracle response: \(String(text.prefix(200)))")
            }
        }
    }

    // MARK: - Check Balance

    /// Call check_balance on an operator's MCP endpoint.
    func callCheckBalance(
        endpointURL: URL,
        bearerToken: String
    ) async throws -> PatronAccountViewModel.BalanceResult {
        await traffic(.outbound, label: "Balance Check", detail: "SSE → \(endpointURL.absoluteString)")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = HTTPClientTransport(
            endpoint: endpointURL,
            streaming: true,
            sseInitializationTimeout: 30,
            requestModifier: { request in
                var req = request
                req.addValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
                return req
            }
        )
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        guard let balanceTool = allTools.first(where: { $0.name.contains("check_balance") }) else {
            await traffic(.error, label: "Balance Check", detail: "No check_balance tool found")
            throw MCPError.toolCallFailed("No check_balance tool found")
        }

        let (content, isError) = try await client.callTool(name: balanceTool.name, arguments: [:])

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            await traffic(.error, label: "Balance Check Error", detail: errorText)
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first,
              let data = text.data(using: .utf8) else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "Balance Check", detail: String(text.prefix(300)))

        return try parseBalanceResponse(data)
    }

    /// Parse the JSON response from check_balance into a BalanceResult.
    private func parseBalanceResponse(_ data: Data) throws -> PatronAccountViewModel.BalanceResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.invalidResponse
        }

        // Handle nested {"result": {...}} wrapper or direct response
        let balanceDict: [String: Any]
        if let result = json["result"] as? [String: Any] {
            balanceDict = result
        } else {
            balanceDict = json
        }

        let balance = (balanceDict["balance_api_sats"] as? Int)
            ?? (balanceDict["balanceApiSats"] as? Int)
            ?? (balanceDict["balance"] as? Int)
            ?? 0
        let deposited = (balanceDict["total_deposited"] as? Int)
            ?? (balanceDict["totalDeposited"] as? Int)
            ?? 0
        let consumed = (balanceDict["total_consumed"] as? Int)
            ?? (balanceDict["totalConsumed"] as? Int)
            ?? 0
        let expired = (balanceDict["total_expired"] as? Int)
            ?? (balanceDict["totalExpired"] as? Int)
            ?? 0
        let tranches = (balanceDict["active_tranches"] as? Int)
            ?? (balanceDict["activeTranches"] as? Int)
            ?? 0
        let expiring24h = (balanceDict["expiring_within_24h"] as? Int)
            ?? (balanceDict["expiringWithin24h"] as? Int)
            ?? 0

        var nextExpiration: Date? = nil
        if let ts = balanceDict["next_expiration"] as? TimeInterval {
            nextExpiration = Date(timeIntervalSince1970: ts)
        } else if let isoStr = balanceDict["next_expiration"] as? String {
            let formatter = ISO8601DateFormatter()
            nextExpiration = formatter.date(from: isoStr)
        }

        return PatronAccountViewModel.BalanceResult(
            balanceApiSats: balance,
            totalDeposited: deposited,
            totalConsumed: consumed,
            totalExpired: expired,
            activeTranches: tranches,
            expiringWithin24h: expiring24h,
            nextExpiration: nextExpiration
        )
    }

    // MARK: - Pricing Synthesis

    /// Connects to an operator's MCP, lists all tools, and synthesizes a pricing model
    /// by inferring category and price from tool names.
    private func synthesizePricingModel(endpointURL: URL, bearerToken: String) async throws -> PricingModelResponse {
        await traffic(.outbound, label: "Operator Connect", detail: "SSE → \(endpointURL.absoluteString) (Bearer auth)")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = HTTPClientTransport(
            endpoint: endpointURL,
            streaming: true,
            sseInitializationTimeout: 30,
            requestModifier: { request in
                var req = request
                req.addValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
                return req
            }
        )
        defer { Task { await client.disconnect() } }
        do {
            try await client.connect(transport: transport)
            await traffic(.inbound, label: "Operator Connected", detail: "SSE session established to \(endpointURL.absoluteString)")
        } catch {
            await traffic(.error, label: "Operator Connect Failed", detail: "URL: \(endpointURL.absoluteString)\nAuthorization: Bearer <token>\nError: \(String(describing: error))\nType: \(type(of: error))")
            throw error
        }

        await traffic(.outbound, label: "Operator listTools", detail: "Listing all tools with pagination")
        let allTools = try await listAllTools(client: client)
        let toolNames = allTools.map(\.name).joined(separator: ", ")
        await traffic(.inbound, label: "Operator listTools → \(allTools.count) tools", detail: toolNames)

        let toolPrices = allTools.map { tool -> ToolPrice in
            let (category, price) = inferCategoryAndPrice(for: tool)
            return ToolPrice(
                toolName: tool.name,
                priceSats: price,
                category: category,
                intent: tool.description ?? ""
            )
        }

        let summary = toolPrices.map { "\($0.toolName): \($0.priceSats) sats (\($0.category))" }.joined(separator: "\n")
        await traffic(.inbound, label: "Pricing synthesized for \(toolPrices.count) tools", detail: summary)

        return PricingModelResponse(
            status: "ok",
            modelId: "synthesized",
            name: "Live Tool Pricing",
            isActive: true,
            tools: toolPrices,
            pipeline: nil
        )
    }

    /// Infer category and sat price from a tool's name using suffix heuristics.
    private func inferCategoryAndPrice(for tool: Tool) -> (category: String, price: Int) {
        let name = tool.name.lowercased()

        // Auth/session tools — free
        if name.contains("session_status") || name.contains("activate_session")
            || name.contains("register_credentials") || name.contains("receive_credentials")
            || name.contains("request_credential") || name.contains("forget_credentials") {
            return ("auth", 0)
        }

        // Explicitly free tools (oracle delegation, balance)
        if name.contains("how_to_join") || name.contains("lookup_member")
            || name.contains("dpyc_about") || name.contains("network_advisory")
            || name.contains("check_balance") || name.contains("get_tax_rate") {
            return ("free", 0)
        }

        // Heavy operations — 10 sats
        if name.contains("morph") || name.contains("paginated")
            || name.contains("purchase_credits") || name.contains("restore_credits") {
            return ("heavy", 10)
        }

        // Write operations — 5 sats
        if name.contains("create") || name.contains("update") || name.contains("delete")
            || name.contains("append") || name.contains("add_file") || name.contains("add_url") {
            return ("write", 5)
        }

        // Default: read — 1 sat
        return ("read", 1)
    }

    // MARK: - Helpers

    /// List all tools with cursor-based pagination.
    private func listAllTools(client: Client) async throws -> [Tool] {
        var allTools: [Tool] = []
        var cursor: String? = nil

        repeat {
            let (tools, nextCursor) = try await client.listTools(cursor: cursor)
            allTools.append(contentsOf: tools)
            cursor = nextCursor
        } while cursor != nil

        return allTools
    }

    /// Extract text content from a Tool.Content value.
    private func extractText(_ content: Tool.Content) -> String? {
        switch content {
        case .text(let text):
            return text
        default:
            return nil
        }
    }

    /// Log a traffic entry (dispatches to MainActor).
    private func traffic(_ direction: TrafficLogEntry.Direction, label: String, detail: String) async {
        await MainActor.run { TrafficLogger.shared.log(direction, label: label, detail: detail) }
    }
}

enum MCPError: LocalizedError {
    case invalidResponse
    case noPricingTool
    case connectionFailed(String)
    case toolCallFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from MCP server"
        case .noPricingTool: return "No pricing model tool found on this operator"
        case .connectionFailed(let msg): return "MCP connection failed: \(msg)"
        case .toolCallFailed(let msg): return "MCP tool call failed: \(msg)"
        }
    }
}
