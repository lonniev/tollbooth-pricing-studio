import Foundation
import SwiftUI

@MainActor
@Observable
final class PricingViewModel {

    enum State: Sendable {
        case idle
        case loading(step: String)
        case loaded(PricingModelResponse)
        case error(String)
    }

    private(set) var state: State = .idle
    private(set) var currentOperatorNpub: String?

    private let mcpService = MCPService()
    private let oauthService = OAuthService()

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    var pricingModel: PricingModelResponse? {
        if case .loaded(let model) = state { return model }
        return nil
    }

    var errorMessage: String? {
        if case .error(let msg) = state { return msg }
        return nil
    }

    var loadingStep: String? {
        if case .loading(let step) = state { return step }
        return nil
    }

    func loadPricing(for op: Operator) async {
        guard currentOperatorNpub != op.npub || errorMessage != nil else { return }
        currentOperatorNpub = op.npub

        state = .loading(step: MCPService.ConnectionStep.resolvingOracle.rawValue)

        do {
            // Step 1: Lookup operator via Oracle
            let member = try await mcpService.lookupOperator(npub: op.npub) { [weak self] step in
                Task { @MainActor in
                    self?.state = .loading(step: step.rawValue)
                }
            }

            // Update cached endpoint
            if let endpoint = member.mcpEndpointURL {
                op.mcpEndpointURL = endpoint
            }

            guard let endpointString = op.mcpEndpointURL,
                  let endpointURL = URL(string: endpointString) else {
                state = .error("No MCP endpoint found for this operator")
                return
            }

            // Step 2: Get auth token (from keychain or fresh OAuth)
            state = .loading(step: MCPService.ConnectionStep.authenticating.rawValue)
            let token: String
            if let cached = KeychainService.loadToken(forOperator: op.npub) {
                token = cached
            } else {
                token = try await oauthService.authenticate(mcpEndpoint: endpointURL)
                try KeychainService.saveToken(token, forOperator: op.npub)
            }

            // Step 3: Fetch pricing model
            let model = try await mcpService.fetchPricingModel(
                endpointURL: endpointURL,
                bearerToken: token
            ) { [weak self] step in
                Task { @MainActor in
                    self?.state = .loading(step: step.rawValue)
                }
            }

            state = .loaded(model)

        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func loadPreview(for op: Operator) {
        currentOperatorNpub = op.npub
        state = .loaded(PreviewData.samplePricingModel)
    }

    func retry(for op: Operator) async {
        currentOperatorNpub = nil
        await loadPricing(for: op)
    }

    func reset() {
        state = .idle
        currentOperatorNpub = nil
    }
}
