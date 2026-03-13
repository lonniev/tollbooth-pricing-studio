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
    private(set) var memberRecord: MemberRecord?

    private let mcpService = MCPService()
    private let oauthService = OAuthService()
    private var loadingTask: Task<Void, Never>?

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
            // Step 1: Resolve Oracle URL and authenticate
            state = .loading(step: MCPService.ConnectionStep.resolvingOracle.rawValue)
            let oracleURL = try await mcpService.resolveOracleURL(forOperator: op.npub)
            let oracleHost = oracleURL.host ?? "oracle"

            state = .loading(step: MCPService.ConnectionStep.authenticating.rawValue)
            let oracleToken = try await resolveToken(for: oracleURL, host: oracleHost)

            // Step 2: Lookup operator via Oracle
            let member = try await mcpService.lookupOperator(npub: op.npub, bearerToken: oracleToken) { [weak self] step in
                Task { @MainActor in
                    self?.state = .loading(step: step.rawValue)
                }
            }

            memberRecord = member

            // Update cached endpoint
            if let endpoint = member.mcpEndpointURL {
                op.mcpEndpointURL = endpoint
            }

            guard let endpointString = op.mcpEndpointURL,
                  let endpointURL = URL(string: endpointString) else {
                state = .error("No MCP endpoint found for this operator")
                return
            }

            // Step 3: Get auth token for operator MCP (may share Horizon with Oracle)
            state = .loading(step: MCPService.ConnectionStep.authenticating.rawValue)
            let operatorHost = endpointURL.host ?? op.npub
            let operatorToken = try await resolveToken(for: endpointURL, host: operatorHost)

            // Step 4: Fetch pricing model
            let model = try await mcpService.fetchPricingModel(
                endpointURL: endpointURL,
                bearerToken: operatorToken
            ) { [weak self] step in
                Task { @MainActor in
                    self?.state = .loading(step: step.rawValue)
                }
            }

            state = .loaded(model)

        } catch is CancellationError {
            // Task cancelled by SwiftUI view lifecycle — not a real error
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession cancelled by task cancellation — not a real error
            return
        } catch {
            let detail = "\(error.localizedDescription)\n\nUnderlying: \(String(describing: error))"
            TrafficLogger.shared.log(.error, label: "Load Failed: \(op.displayName)", detail: detail)
            state = .error(error.localizedDescription)
        }
    }

    func loadPreview(for op: Operator) {
        currentOperatorNpub = op.npub
        state = .loaded(PreviewData.samplePricingModel)
    }

    func startLoading(for op: Operator) {
        loadingTask?.cancel()
        loadingTask = Task {
            await loadPricing(for: op)
        }
    }

    func cancel() {
        loadingTask?.cancel()
        loadingTask = nil
        state = .idle
        currentOperatorNpub = nil
        memberRecord = nil
    }

    func retry(for op: Operator) {
        currentOperatorNpub = nil
        startLoading(for: op)
    }

    func reset() {
        loadingTask?.cancel()
        loadingTask = nil
        state = .idle
        currentOperatorNpub = nil
        memberRecord = nil
    }

    // MARK: - Token Resolution

    /// Resolve a valid access token: cached bundle → refresh → full re-auth.
    private func resolveToken(for endpoint: URL, host: String) async throws -> String {
        // 1. Check for a cached bundle
        if let bundle = KeychainService.loadTokenBundle(forOperator: host) {
            if !bundle.isExpired {
                return bundle.accessToken
            }

            // 2. Token expired — try refresh
            if bundle.refreshToken != nil {
                do {
                    let refreshed = try await oauthService.refresh(bundle: bundle)
                    try KeychainService.saveTokenBundle(refreshed, forOperator: host)
                    return refreshed.accessToken
                } catch {
                    TrafficLogger.shared.log(.error, label: "Token Refresh Failed", detail: "\(host): \(error.localizedDescription) — falling back to re-auth")
                }
            }

            // Refresh failed or unavailable — clear stale bundle
            KeychainService.deleteTokenBundle(forOperator: host)
        }

        // 3. No valid cached token — full OAuth dance
        let bundle = try await oauthService.authenticate(mcpEndpoint: endpoint)
        try KeychainService.saveTokenBundle(bundle, forOperator: host)
        return bundle.accessToken
    }
}
