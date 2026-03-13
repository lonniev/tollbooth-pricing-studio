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

    /// Called when an operator lookup discovers an upstream authority.
    /// Parameters: (authorityNpub, displayName?, endpointURL?)
    var onAuthorityDiscovered: ((String, String?, String?) -> Void)?

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

    func loadPricing(for target: any PricingTarget) async {
        guard currentOperatorNpub != target.npub || errorMessage != nil else { return }
        currentOperatorNpub = target.npub

        state = .loading(step: MCPService.ConnectionStep.resolvingOracle.rawValue)

        do {
            // Step 1: Resolve Oracle URL and authenticate
            state = .loading(step: MCPService.ConnectionStep.resolvingOracle.rawValue)
            let oracleURL = try await mcpService.resolveOracleURL(forOperator: target.npub)
            let oracleHost = oracleURL.host ?? "oracle"

            state = .loading(step: MCPService.ConnectionStep.authenticating.rawValue)
            let oracleToken = try await resolveToken(for: oracleURL, host: oracleHost)

            // Step 2: Lookup via Oracle
            let member = try await mcpService.lookupOperator(npub: target.npub, bearerToken: oracleToken) { [weak self] step in
                Task { @MainActor in
                    self?.state = .loading(step: step.rawValue)
                }
            }

            memberRecord = member

            // Update cached endpoint
            if let endpoint = member.mcpEndpointURL {
                target.mcpEndpointURL = endpoint
            }

            // Auto-discover upstream authority (Operator-specific)
            if let op = target as? Operator, let authNpub = member.upstreamAuthorityNpub {
                op.authorityNpub = authNpub
                // Look up the authority's display name and endpoint from registry
                let authInfo = await resolveAuthorityInfo(npub: authNpub)
                onAuthorityDiscovered?(authNpub, authInfo.displayName, authInfo.endpointURL)
            }

            guard let endpointString = target.mcpEndpointURL,
                  let endpointURL = URL(string: endpointString) else {
                state = .error("No MCP endpoint found for this entity")
                return
            }

            // Step 3: Get auth token for MCP endpoint
            state = .loading(step: MCPService.ConnectionStep.authenticating.rawValue)
            let targetHost = endpointURL.host ?? target.npub
            let targetToken = try await resolveToken(for: endpointURL, host: targetHost)

            // Step 4: Fetch pricing model
            let model = try await mcpService.fetchPricingModel(
                endpointURL: endpointURL,
                bearerToken: targetToken
            ) { [weak self] step in
                Task { @MainActor in
                    self?.state = .loading(step: step.rawValue)
                }
            }

            state = .loaded(model)

        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            let detail = "\(error.localizedDescription)\n\nUnderlying: \(String(describing: error))"
            TrafficLogger.shared.log(.error, label: "Load Failed: \(target.displayName)", detail: detail)
            state = .error(error.localizedDescription)
        }
    }

    func loadPreview(for target: any PricingTarget) {
        currentOperatorNpub = target.npub
        state = .loaded(PreviewData.samplePricingModel)
    }

    func startLoading(for target: any PricingTarget) {
        loadingTask?.cancel()
        loadingTask = Task {
            await loadPricing(for: target)
        }
    }

    func cancel() {
        loadingTask?.cancel()
        loadingTask = nil
        state = .idle
        currentOperatorNpub = nil
        memberRecord = nil
    }

    func retry(for target: any PricingTarget) {
        currentOperatorNpub = nil
        startLoading(for: target)
    }

    func reset() {
        loadingTask?.cancel()
        loadingTask = nil
        state = .idle
        currentOperatorNpub = nil
        memberRecord = nil
    }

    // MARK: - Authority Discovery

    /// Look up an authority's display name and MCP endpoint from the registry.
    private func resolveAuthorityInfo(npub: String) async -> (displayName: String?, endpointURL: String?) {
        do {
            let entries = try await RegistryService.fetchRegistry()
            guard let entry = entries.first(where: { $0.npub == npub }) else {
                return (nil, nil)
            }
            let endpointURL = entry.services?.first?.url
            return (entry.display_name, endpointURL)
        } catch {
            return (nil, nil)
        }
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
