import Foundation
import MCP
import SwiftData
import UIKit

/// Drives the "Test Call as Npub" feature — lets users select an operator,
/// pick a tool, choose an npub identity, fill in parameters from the tool's
/// schema, check affordability, and execute.
@MainActor @Observable
final class TestCallViewModel {

    enum State: Sendable {
        case idle
        case loadingTools
        case toolsLoaded
        case checkingBalance
        case ready(ToolCostEstimate)
        case executing
        case oauthPolling(secondsRemaining: Int)
        case result(String)
        case error(String)
    }

    struct ToolCostEstimate: Sendable {
        let toolName: String
        let intent: String
        let effectiveCostSats: Int      // after constraint chain
        let baseCostSats: Int           // before constraint chain
        let currentBalanceSats: Int
        let requiredRole: ToolRole
        var canAfford: Bool { effectiveCostSats == 0 || currentBalanceSats >= effectiveCostSats }
        var isDiscounted: Bool { effectiveCostSats != baseCostSats }
    }

    /// A parameter from the tool's input schema.
    struct ToolParam: Identifiable, Sendable {
        let id: String  // param name
        let name: String
        let description: String
        let type: String  // "string", "integer", "number", "boolean"
        let required: Bool
        let defaultValue: String
    }

    private(set) var state: State = .idle
    private(set) var availableTools: [ToolPrice] = []

    /// Schema-derived parameters for the selected tool.
    private(set) var toolParams: [ToolParam] = []

    /// User-editable values for each parameter, keyed by param name.
    var paramValues: [String: String] = [:]

    /// Cached MCP tool schemas keyed by full tool name.
    private var toolSchemas: [String: Value] = [:]

    var selectedOperator: Operator? {
        didSet {
            if selectedOperator?.npub != oldValue?.npub {
                availableTools = []
                selectedTool = nil
                selectedPatronNpub = nil
                toolParams = []
                paramValues = [:]
                toolSchemas = [:]
                state = .idle
            }
        }
    }

    var selectedTool: ToolPrice? {
        didSet {
            if selectedTool?.toolName != oldValue?.toolName {
                selectedPatronNpub = nil
                updateToolParams()
                if !availableTools.isEmpty { state = .toolsLoaded }
            }
        }
    }

    /// Which tactic produced the auto-filled proof for the current selection.
    /// Surfaced to the View so the user knows whether they need to do a
    /// Secure Courier round-trip or whether the App signed locally.
    enum ProofTactic: Sendable {
        case schnorrFromKeychain   // Signed inline from nsec — no DM needed
        case cachedPoisonToken     // Cached proof_token from prior receive_npub_proof
        case noneAvailable         // User must run request/receive npub_proof
    }

    private(set) var proofTactic: ProofTactic = .noneAvailable

    var selectedPatronNpub: String? {
        didSet {
            guard let npub = selectedPatronNpub else { return }
            if toolParams.contains(where: { $0.name == "npub" }) {
                paramValues["npub"] = npub
            }
            guard toolParams.contains(where: { $0.name == "proof" }),
                  let toolName = selectedTool?.toolName, !toolName.isEmpty else {
                proofTactic = .noneAvailable
                return
            }
            // Single canonical tactic-selection — mirrors MCPService.argsWithProof.
            // Wheel v0.24.0 require_proof checks the runtime tool name (mcp_name),
            // which is exactly what the pricing model lists. Sign that name
            // directly — no slug-strip, no capability lookup.
            if let proof = try? OperatorProofService.createProof(toolName: toolName, operatorNpub: npub) {
                paramValues["proof"] = proof
                proofTactic = .schnorrFromKeychain
                return
            }
            let host = selectedOperator?.mcpEndpointURL
                .flatMap { URL(string: $0)?.host } ?? ""
            if let token = KeychainService.loadProofToken(forPatron: npub, operator: host), !token.isEmpty {
                paramValues["proof"] = token
                proofTactic = .cachedPoisonToken
                return
            }
            paramValues["proof"] = ""
            proofTactic = .noneAvailable
        }
    }

    /// Whether the currently-selected tool has a ``patron_proof`` constraint
    /// in its chain.  Each tool walks its own chain at debit time, so this
    /// is a per-tool check, not an operator-wide one (0.40.0+).
    var toolRequiresPatronProof: Bool {
        guard let selected = selectedTool else { return false }
        return selected.chain.contains { $0.type == "patron_proof" }
    }

    private let mcpService = MCPService()

    // MARK: - Load Tools

    func loadTools() async {
        guard let op = selectedOperator,
              let endpointString = op.mcpEndpointURL,
              let endpoint = URL(string: endpointString) else {
            state = .error("No MCP endpoint configured for this operator")
            return
        }

        state = .loadingTools

        do {

            // Fetch pricing model for tool list + costs
            let result = try await mcpService.fetchPricingModel(
                endpointURL: endpoint,
                onStep: { _ in }
            )
            availableTools = result.tools ?? []

            // Fetch MCP tool schemas for parameter info
            let mcpTools = try await mcpService.fetchToolList(
                endpointURL: endpoint
            )
            toolSchemas = [:]
            for tool in mcpTools {
                toolSchemas[tool.name] = tool.inputSchema
            }

            // No fabrication of placeholder entries — only tools in the
            // pricing model are shown. Reconciliation handles discovery.

            state = .toolsLoaded
        } catch {
            state = .error("Failed to load tools: \(error.localizedDescription)")
        }
    }

    // MARK: - Schema Parsing

    /// Parse the selected tool's inputSchema and populate toolParams.
    private func updateToolParams() {
        toolParams = []
        paramValues = [:]

        guard let toolName = selectedTool?.toolName else { return }

        // Find the matching MCP tool schema (try exact, then suffix match)
        let schema: Value?
        if let exact = toolSchemas[toolName] {
            schema = exact
        } else if let match = toolSchemas.first(where: { $0.key.hasSuffix("_\(toolName)") }) {
            schema = match.value
        } else {
            schema = nil
        }

        guard let schema,
              case .object(let obj) = schema,
              let propsVal = obj["properties"],
              case .object(let properties) = propsVal else { return }

        // Extract required field names
        var requiredNames: Set<String> = []
        if let reqVal = obj["required"], case .array(let reqArr) = reqVal {
            for item in reqArr {
                if case .string(let name) = item {
                    requiredNames.insert(name)
                }
            }
        }

        for (name, propVal) in properties {
            guard case .object(let prop) = propVal else { continue }

            let type: String
            if let typeVal = prop["type"], case .string(let t) = typeVal {
                type = t
            } else {
                type = "string"
            }

            let description: String
            if let descVal = prop["description"], case .string(let d) = descVal {
                description = d
            } else {
                description = ""
            }

            let defaultStr: String
            if let defVal = prop["default"] {
                switch defVal {
                case .string(let s): defaultStr = s
                case .int(let i): defaultStr = "\(i)"
                case .double(let f): defaultStr = "\(f)"
                case .bool(let b): defaultStr = b ? "true" : "false"
                default: defaultStr = ""
                }
            } else {
                defaultStr = ""
            }

            toolParams.append(ToolParam(
                id: name,
                name: name,
                description: description,
                type: type,
                required: requiredNames.contains(name),
                defaultValue: defaultStr
            ))

            // Pre-fill default values
            if !defaultStr.isEmpty {
                paramValues[name] = defaultStr
            }
        }

        // Sort: required first, then alphabetical
        toolParams.sort { a, b in
            if a.required != b.required { return a.required }
            return a.name < b.name
        }
    }

    // MARK: - Build Arguments

    /// Build the tool call arguments from paramValues, filtering empty optionals.
    private func buildArguments() -> [String: Value] {
        var args: [String: Value] = [:]
        for param in toolParams {
            let value = paramValues[param.name, default: ""]
            if value.isEmpty && !param.required { continue }
            if value.isEmpty { continue }

            switch param.type {
            case "integer":
                args[param.name] = .int(Int(value) ?? 0)
            case "number":
                args[param.name] = .double(Double(value) ?? 0)
            case "boolean":
                args[param.name] = .bool(value == "true")
            default:
                args[param.name] = .string(value)
            }
        }
        return args
    }

    // MARK: - Check Affordability

    func checkAffordability() async {
        guard let op = selectedOperator,
              let endpointString = op.mcpEndpointURL,
              let endpoint = URL(string: endpointString),
              let tool = selectedTool,
              let patronNpub = selectedPatronNpub else {
            state = .error("Select an operator, tool, and identity first")
            return
        }

        let role = ToolRoleClassifier.classify(tool.toolName)

        // Operator tools don't need balance checks
        if role == .operator {
            state = .ready(ToolCostEstimate(
                toolName: tool.toolName,
                intent: tool.intent,
                effectiveCostSats: 0,
                baseCostSats: 0,
                currentBalanceSats: 0,
                requiredRole: role
            ))
            return
        }

        state = .checkingBalance

        do {
            async let balanceTask = mcpService.callCheckBalance(
                endpointURL: endpoint,
                patronNpub: patronNpub
            )
            async let priceTask = mcpService.callCheckPrice(
                endpointURL: endpoint,
                toolId: tool.toolId,
                patronNpub: patronNpub
            )
            let balance = try await balanceTask
            let price = try await priceTask
            state = .ready(ToolCostEstimate(
                toolName: tool.toolName,
                intent: tool.intent,
                effectiveCostSats: price.effectiveCostSats,
                baseCostSats: price.baseCostSats,
                currentBalanceSats: balance.balanceApiSats,
                requiredRole: role
            ))
        } catch {
            state = .error("Affordability check failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Execute

    func executeCall() async {
        guard let op = selectedOperator,
              let endpointString = op.mcpEndpointURL,
              let endpoint = URL(string: endpointString),
              let _ = selectedTool,
              let _ = selectedPatronNpub else {
            state = .error("Missing operator or tool selection")
            return
        }

        state = .executing

        do {
            var args = buildArguments()

            // If the tool requires patron_proof (from pipeline), sign it.
            // Use the short capability name to match what verify_proof checks.
            if toolRequiresPatronProof, let patronNpub = selectedPatronNpub {
                let proof = try OperatorProofService.createProof(
                    toolName: selectedTool!.toolName,  // runtime name from pricing model
                    operatorNpub: patronNpub  // works for any npub with nsec in Keychain
                )
                args["patron_proof"] = .string(proof)
            }

            let response = try await mcpService.callToolGeneric(
                endpointURL: endpoint,
                toolName: selectedTool!.toolName,
                arguments: args
            )

            // When the user runs receive_npub_proof via Execute Tool,
            // capture the returned proof_token to Keychain so subsequent
            // paid calls (e.g. account_statement_infographic) can find it
            // via argsWithProof without further user action.
            if selectedTool!.toolName.hasSuffix("receive_npub_proof"),
               let patronNpub = selectedPatronNpub {
                persistProofToken(from: response, endpoint: endpoint, patronNpub: patronNpub)
            }

            // Detect OAuth dance: begin_oauth returns authorize_url
            if let authorizeURL = extractAuthorizeURL(from: response) {
                await beginOAuthPolling(
                    authorizeURL: authorizeURL,
                    endpoint: endpoint
                )
            } else {
                state = .result(response)
            }
        } catch {
            state = .error("Tool call failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Proof Token Persistence

    /// Extract `proof_token` from a successful receive_npub_proof response
    /// and cache it in Keychain for the (patron, operatorHost) pair, so
    /// subsequent paid tool calls can find it via argsWithProof.
    private func persistProofToken(from response: String, endpoint: URL, patronNpub: String) {
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["success"] as? Bool == true,
              let token = json["proof_token"] as? String else {
            return
        }
        let host = endpoint.host ?? endpoint.absoluteString
        try? KeychainService.saveProofToken(token, forPatron: patronNpub, operator: host)
    }

    // MARK: - OAuth Dance

    /// Detect an authorize_url in a begin_oauth response.
    private func extractAuthorizeURL(from response: String) -> URL? {
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = json["authorize_url"] as? String,
              let url = URL(string: urlString) else {
            return nil
        }
        return url
    }

    /// Open browser and poll check_oauth_status until completed or timeout.
    private func beginOAuthPolling(
        authorizeURL: URL,
        endpoint: URL
    ) async {
        // Open browser for user to authorize
        await UIApplication.shared.open(authorizeURL)

        let pollInterval: UInt64 = 2_000_000_000  // 2 seconds
        let maxSeconds = 30
        let maxPolls = maxSeconds / 2

        for i in 0..<maxPolls {
            let remaining = maxSeconds - (i * 2)
            state = .oauthPolling(secondsRemaining: remaining)

            try? await Task.sleep(nanoseconds: pollInterval)

            do {
                // Build args for check_oauth_status — reuse the npub param
                var checkArgs: [String: Value] = [:]
                if let npub = selectedPatronNpub {
                    // Try both param names since operators vary
                    if toolParams.contains(where: { $0.name == "patron_npub" }) {
                        checkArgs["patron_npub"] = .string(npub)
                    } else {
                        checkArgs["npub"] = .string(npub)
                    }
                }

                let response = try await mcpService.callToolGeneric(
                    endpointURL: endpoint,
                    toolName: "check_oauth_status",
                    arguments: checkArgs
                )

                // Parse status
                if let data = response.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? String,
                   status == "completed" {
                    state = .result(response)
                    return
                }
                // "pending" — keep polling
            } catch {
                // Transient error — keep polling unless fatal
                continue
            }
        }

        state = .error("OAuth authorization timed out after \(maxSeconds)s. The authorization code may have expired — try again.")
    }

    // MARK: - Helpers

    /// Get available identity npubs filtered by the selected tool's role requirement.
    func availableIdentities(operators: [Operator], patrons: [Patron], authorities: [Authority] = []) -> [(npub: String, displayName: String, role: ToolRole)] {
        var seen = Set<String>()
        var identities: [(npub: String, displayName: String, role: ToolRole)] = []

        // Patrons first (alias names are most specific)
        for patron in patrons where KeychainService.loadNsec(forNpub: patron.npub) != nil {
            if seen.insert(patron.npub).inserted {
                identities.append((patron.npub, patron.displayName, .patron))
            }
        }
        // Operators
        for op in operators where KeychainService.loadNsec(forNpub: op.npub) != nil {
            if seen.insert(op.npub).inserted {
                identities.append((op.npub, op.displayName, .operator))
            }
        }
        // Authorities (they're also operators)
        for auth in authorities where KeychainService.loadNsec(forNpub: auth.npub) != nil {
            if seen.insert(auth.npub).inserted {
                identities.append((auth.npub, auth.displayName, .operator))
            }
        }

        return identities
    }
}
