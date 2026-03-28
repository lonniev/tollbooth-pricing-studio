import Foundation
import SwiftData

/// Drives the "Test Call as Npub" feature — lets users select an operator,
/// pick a tool, choose an npub identity, check affordability, and optionally execute.
@MainActor @Observable
final class TestCallViewModel {

    enum State: Sendable {
        case idle
        case loadingTools
        case toolsLoaded
        case checkingBalance
        case ready(ToolCostEstimate)
        case executing
        case result(String)
        case error(String)
    }

    struct ToolCostEstimate: Sendable {
        let toolName: String
        let intent: String
        let estimatedCostSats: Int
        let currentBalanceSats: Int
        var canAfford: Bool { currentBalanceSats >= estimatedCostSats }
        let requiredRole: ToolRole
    }

    private(set) var state: State = .idle
    private(set) var availableTools: [ToolPrice] = []

    var selectedOperator: Operator? {
        didSet {
            if selectedOperator?.npub != oldValue?.npub {
                availableTools = []
                selectedTool = nil
                selectedPatronNpub = nil
                state = .idle
            }
        }
    }

    var selectedTool: ToolPrice? {
        didSet {
            if selectedTool?.toolName != oldValue?.toolName {
                selectedPatronNpub = nil
                if !availableTools.isEmpty { state = .toolsLoaded }
            }
        }
    }

    var selectedPatronNpub: String?

    private let mcpService = MCPService()
    private let oauthService = OAuthService()

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
            let token = try await resolveToken(operatorNpub: op.npub, endpoint: endpoint)
            let result = try await mcpService.fetchPricingModel(
                endpointURL: endpoint,
                bearerToken: token,
                onStep: { _ in }
            )
            availableTools = result.tools ?? []
            state = .toolsLoaded
        } catch {
            state = .error("Failed to load tools: \(error.localizedDescription)")
        }
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
                estimatedCostSats: 0,
                currentBalanceSats: 0,
                requiredRole: role
            ))
            return
        }

        state = .checkingBalance

        do {
            let token = try await resolveToken(patronNpub: patronNpub, operatorNpub: op.npub, endpoint: endpoint)
            let balance = try await mcpService.callCheckBalance(
                endpointURL: endpoint,
                bearerToken: token,
                patronNpub: patronNpub
            )
            state = .ready(ToolCostEstimate(
                toolName: tool.toolName,
                intent: tool.intent,
                estimatedCostSats: tool.priceSats,
                currentBalanceSats: balance.balanceApiSats,
                requiredRole: role
            ))
        } catch {
            state = .error("Balance check failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Execute

    func executeCall() async {
        guard let op = selectedOperator,
              let endpointString = op.mcpEndpointURL,
              let endpoint = URL(string: endpointString),
              let tool = selectedTool,
              let npub = selectedPatronNpub else {
            state = .error("Missing operator or tool selection")
            return
        }

        state = .executing

        do {
            let token = try await resolveToken(patronNpub: npub, operatorNpub: op.npub, endpoint: endpoint)
            let response = try await mcpService.callToolGeneric(
                endpointURL: endpoint,
                bearerToken: token,
                toolName: tool.toolName,
                arguments: ["npub": .string(npub)]
            )
            state = .result(response)
        } catch {
            state = .error("Tool call failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Token Resolution

    private func resolveToken(patronNpub: String? = nil, operatorNpub: String, endpoint: URL) async throws -> String {
        let operatorHost = endpoint.host ?? operatorNpub
        let npub = patronNpub ?? operatorNpub

        // Check cached token
        if let bundle = KeychainService.loadTokenBundle(forPatron: npub, operator: operatorHost) {
            if !bundle.isExpired { return bundle.accessToken }
            if bundle.refreshToken != nil {
                if let refreshed = try? await oauthService.refresh(bundle: bundle) {
                    try? KeychainService.saveTokenBundle(refreshed, forPatron: npub, operator: operatorHost)
                    return refreshed.accessToken
                }
            }
            KeychainService.deleteTokenBundle(forPatron: npub, operator: operatorHost)
        }

        // Full OAuth
        let bundle = try await oauthService.authenticate(mcpEndpoint: endpoint)
        try KeychainService.saveTokenBundle(bundle, forPatron: npub, operator: operatorHost)
        return bundle.accessToken
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
