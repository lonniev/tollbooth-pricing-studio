import Foundation

actor MCPService {

    enum ConnectionStep: String, Sendable {
        case resolvingOracle = "Resolving Oracle endpoint..."
        case lookingUpOperator = "Looking up operator..."
        case authenticating = "Authenticating with Horizon..."
        case connectingToOperator = "Connecting to operator MCP..."
        case fetchingPricing = "Fetching pricing model..."
        case done = "Done"
    }

    func lookupOperator(npub: String, onStep: @Sendable (ConnectionStep) -> Void) async throws -> MemberRecord {
        onStep(.resolvingOracle)
        let oracleURL = try await RegistryService.resolveOracleURL()

        onStep(.lookingUpOperator)
        return try await callOracleLookup(oracleURL: oracleURL, npub: npub)
    }

    func fetchPricingModel(
        endpointURL: URL,
        bearerToken: String,
        onStep: @Sendable (ConnectionStep) -> Void
    ) async throws -> PricingModelResponse {
        onStep(.connectingToOperator)

        onStep(.fetchingPricing)
        let result = try await callPricingTool(endpointURL: endpointURL, bearerToken: bearerToken)

        onStep(.done)
        return result
    }

    private func callOracleLookup(oracleURL: URL, npub: String) async throws -> MemberRecord {
        // Connect to Oracle MCP via SSE and call lookup_member
        // Oracle is free and unauthenticated
        let sseURL = oracleURL.appendingPathComponent("sse")
        let toolName = "lookup_member"
        let arguments: [String: Any] = ["npub": npub]

        let result = try await callMCPTool(
            sseURL: sseURL,
            toolName: toolName,
            arguments: arguments,
            bearerToken: nil
        )

        guard let data = result.data(using: .utf8) else {
            throw MCPError.invalidResponse
        }
        return try JSONDecoder().decode(MemberRecord.self, from: data)
    }

    private func callPricingTool(endpointURL: URL, bearerToken: String) async throws -> PricingModelResponse {
        let sseURL = endpointURL.appendingPathComponent("sse")

        // First list tools to find the pricing tool
        let toolName = try await discoverPricingTool(sseURL: sseURL, bearerToken: bearerToken)

        let result = try await callMCPTool(
            sseURL: sseURL,
            toolName: toolName,
            arguments: [:],
            bearerToken: bearerToken
        )

        guard let data = result.data(using: .utf8) else {
            throw MCPError.invalidResponse
        }
        return try JSONDecoder().decode(PricingModelResponse.self, from: data)
    }

    private func discoverPricingTool(sseURL: URL, bearerToken: String) async throws -> String {
        // Use MCP listTools to find a tool containing "fetch_active_pricing_model"
        let toolsJSON = try await listMCPTools(sseURL: sseURL, bearerToken: bearerToken)

        struct ToolInfo: Codable {
            let name: String
        }
        guard let data = toolsJSON.data(using: .utf8) else {
            throw MCPError.noPricingTool
        }
        let tools = try JSONDecoder().decode([ToolInfo].self, from: data)
        guard let pricingTool = tools.first(where: { $0.name.contains("fetch_active_pricing_model") }) else {
            throw MCPError.noPricingTool
        }
        return pricingTool.name
    }

    // MARK: - Low-level MCP over SSE

    private func listMCPTools(sseURL: URL, bearerToken: String?) async throws -> String {
        // Placeholder: real implementation uses MCP Swift SDK Client + HTTPClientTransport
        // For now, return empty array — this will be replaced with SDK integration
        throw MCPError.notImplemented("MCP SDK integration pending — use preview data")
    }

    private func callMCPTool(
        sseURL: URL,
        toolName: String,
        arguments: [String: Any],
        bearerToken: String?
    ) async throws -> String {
        // Placeholder: real implementation uses MCP Swift SDK Client + HTTPClientTransport
        // For now, throw — this will be replaced with SDK integration
        throw MCPError.notImplemented("MCP SDK integration pending — use preview data")
    }
}

enum MCPError: LocalizedError {
    case invalidResponse
    case noPricingTool
    case connectionFailed(String)
    case toolCallFailed(String)
    case notImplemented(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from MCP server"
        case .noPricingTool: return "No pricing model tool found on this operator"
        case .connectionFailed(let msg): return "MCP connection failed: \(msg)"
        case .toolCallFailed(let msg): return "MCP tool call failed: \(msg)"
        case .notImplemented(let msg): return msg
        }
    }
}
