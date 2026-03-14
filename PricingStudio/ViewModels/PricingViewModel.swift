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
        case cancelled
    }

    private(set) var state: State = .idle
    private(set) var currentOperatorNpub: String?
    private(set) var memberRecord: MemberRecord?
    /// When the current result was fetched — nil if not from cache or not yet loaded.
    private(set) var loadedAt: Date?

    /// Called when an operator lookup discovers an upstream authority.
    /// Parameters: (authorityNpub, displayName?, endpointURL?)
    var onAuthorityDiscovered: ((String, String?, String?) -> Void)?

    private let mcpService = MCPService()
    private let oauthService = OAuthService()
    private var loadingTask: Task<Void, Never>?

    // MARK: - Local Edits

    var localEdits: [String: ToolPrice] = [:]

    func editedTool(for toolName: String) -> ToolPrice? {
        localEdits[toolName]
    }

    func applyEdit(toolName: String, priceSats: Int, priceType: PriceType, priceFormula: String?) {
        guard let model = pricingModel, let tools = model.tools,
              var tool = tools.first(where: { $0.toolName == toolName }) else { return }
        tool.priceSats = priceSats
        tool.priceType = priceType
        tool.priceFormula = priceFormula
        localEdits[toolName] = tool
    }

    func resetEdit(toolName: String) {
        localEdits.removeValue(forKey: toolName)
    }

    func resetAllEdits() {
        localEdits.removeAll()
    }

    var hasEdits: Bool {
        !localEdits.isEmpty
    }

    // MARK: - In-Memory Discovery Cache (5-minute TTL)

    private struct CacheEntry {
        let model: PricingModelResponse
        let memberRecord: MemberRecord?
        let cachedAt: Date

        var isExpired: Bool {
            Date().timeIntervalSince(cachedAt) > 300  // 5 minutes
        }
    }

    private var cache: [String: CacheEntry] = [:]

    // MARK: - Computed State

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

    /// How many seconds ago the current result was fetched.
    var cacheAgeSecs: Int? {
        guard let loadedAt else { return nil }
        return Int(Date().timeIntervalSince(loadedAt))
    }

    // MARK: - Loading

    func loadPricing(for target: any PricingTarget) async {
        // Already showing this target and not in error? Skip.
        guard currentOperatorNpub != target.npub || errorMessage != nil else { return }
        currentOperatorNpub = target.npub

        // Check cache first
        if let entry = cache[target.npub], !entry.isExpired {
            memberRecord = entry.memberRecord
            loadedAt = entry.cachedAt
            state = .loaded(entry.model)
            return
        }

        await fetchPricing(for: target)
    }

    /// Bypass cache — always does a full network round-trip.
    func forceRefresh(for target: any PricingTarget) {
        cache.removeValue(forKey: target.npub)
        currentOperatorNpub = nil  // allow loadPricing guard to pass
        startLoading(for: target)
    }

    private func fetchPricing(for target: any PricingTarget) async {
        state = .loading(step: MCPService.ConnectionStep.resolvingOracle.rawValue)

        do {
            try await fetchPricingSteps(for: target)
        } catch is CancellationError {
            if case .loading = state { state = .idle }
        } catch let urlError as URLError where urlError.code == .cancelled {
            if case .loading = state { state = .idle }
        } catch {
            let detail = "\(error.localizedDescription)\n\nUnderlying: \(String(describing: error))"
            TrafficLogger.shared.log(.error, label: "Load Failed: \(target.displayName)", detail: detail)
            state = .error(error.localizedDescription)
        }
    }

    private func fetchPricingSteps(for target: any PricingTarget) async throws {
        try Task.checkCancellation()

        // Step 1: Resolve Oracle URL and authenticate
        let oracleURL = try await mcpService.resolveOracleURL(forOperator: target.npub)
        let oracleHost = oracleURL.host ?? "oracle"

        try Task.checkCancellation()
        state = .loading(step: MCPService.ConnectionStep.authenticating.rawValue)
        let oracleToken = try await resolveToken(for: oracleURL, host: oracleHost)

        try Task.checkCancellation()

        // Step 2: Lookup via Oracle
        let member = try await mcpService.lookupOperator(npub: target.npub, bearerToken: oracleToken) { [weak self] step in
            guard !Task.isCancelled else { return }
            Task { @MainActor in
                guard !Task.isCancelled else { return }
                self?.state = .loading(step: step.rawValue)
            }
        }

        try Task.checkCancellation()
        memberRecord = member

        // Update cached endpoint
        if let endpoint = member.mcpEndpointURL {
            target.mcpEndpointURL = endpoint
        }

        // Auto-discover upstream authority (Operator-specific)
        if let op = target as? Operator, let authNpub = member.upstreamAuthorityNpub {
            op.authorityNpub = authNpub
            let authInfo = await resolveAuthorityInfo(npub: authNpub)
            onAuthorityDiscovered?(authNpub, authInfo.displayName, authInfo.endpointURL)
        }

        guard let endpointString = target.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else {
            state = .error("No MCP endpoint found for this entity")
            return
        }

        try Task.checkCancellation()

        // Step 3: Get auth token for MCP endpoint
        state = .loading(step: MCPService.ConnectionStep.authenticating.rawValue)
        let targetHost = endpointURL.host ?? target.npub
        let targetToken = try await resolveToken(for: endpointURL, host: targetHost)

        try Task.checkCancellation()

        // Step 4: Fetch pricing model
        let model = try await mcpService.fetchPricingModel(
            endpointURL: endpointURL,
            bearerToken: targetToken
        ) { [weak self] step in
            guard !Task.isCancelled else { return }
            Task { @MainActor in
                guard !Task.isCancelled else { return }
                self?.state = .loading(step: step.rawValue)
            }
        }

        try Task.checkCancellation()

        let now = Date()
        cache[target.npub] = CacheEntry(model: model, memberRecord: member, cachedAt: now)
        loadedAt = now
        state = .loaded(model)
    }

    // MARK: - Save Pricing

    func savePricing(for target: any PricingTarget) async throws {
        guard let model = pricingModel,
              let endpointString = target.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else { return }

        state = .loading(step: "Saving pricing...")

        let targetHost = endpointURL.host ?? target.npub
        let token = try await resolveToken(for: endpointURL, host: targetHost)

        // Merge local edits into model
        let mergedModel = mergeEdits(into: model)

        _ = try await mcpService.callSetPricingModel(
            endpointURL: endpointURL,
            bearerToken: token,
            model: mergedModel
        )

        // Clear local edits after successful save
        localEdits.removeAll()

        // Invalidate cache and reload
        cache.removeValue(forKey: target.npub)
        currentOperatorNpub = nil
        await loadPricing(for: target)
    }

    private func mergeEdits(into model: PricingModelResponse) -> PricingModelResponse {
        guard var tools = model.tools, !localEdits.isEmpty else { return model }
        for (name, edited) in localEdits {
            if let idx = tools.firstIndex(where: { $0.toolName == name }) {
                tools[idx] = edited
            }
        }
        return PricingModelResponse(
            status: model.status,
            modelId: model.modelId,
            name: model.name,
            isActive: model.isActive,
            tools: tools,
            pipeline: model.pipeline,
            source: model.source
        )
    }

    func loadPreview(for target: any PricingTarget) {
        currentOperatorNpub = target.npub
        loadedAt = Date()
        state = .loaded(PreviewData.samplePricingModel)
    }

    func startLoading(for target: any PricingTarget) {
        loadingTask?.cancel()
        currentOperatorNpub = nil  // clear so loadPricing guard passes for new target
        loadingTask = Task {
            await loadPricing(for: target)
        }
    }

    func cancel() {
        loadingTask?.cancel()
        loadingTask = nil
        state = .cancelled
        currentOperatorNpub = nil
        memberRecord = nil
        loadedAt = nil
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
        loadedAt = nil
        // NOTE: cache is intentionally NOT cleared — survives selection changes
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

