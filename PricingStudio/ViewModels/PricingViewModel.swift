import Foundation
import MCP
import SwiftUI

@MainActor
@Observable
final class PricingViewModel {

    enum State: Sendable {
        case idle
        case loading(step: String)
        case loaded(PricingModelResponse)
        case error(String)
        case notRegistered
        case registeredNotConfigured  // In community registry but MCP not serving yet
        case cancelled
    }

    private(set) var state: State = .idle
    private(set) var currentOperatorNpub: String?
    private(set) var memberRecord: MemberRecord?
    /// When the current result was fetched — nil if not from cache or not yet loaded.
    private(set) var loadedAt: Date?
    /// Package versions from the operator's `service_status` tool.
    private(set) var serviceVersions: [String: String]?

    /// Called when an operator lookup discovers an upstream authority.
    /// Parameters: (authorityNpub, displayName?, endpointURL?)
    var onAuthorityDiscovered: ((String, String?, String?) -> Void)?

    private let mcpService = MCPService()
    private var loadingTask: Task<Void, Never>?

    // MARK: - Local Edits

    var localEdits: [String: ToolPrice] = [:]
    var localRemovals: Set<String> = []
    var localPipeline: [PipelineStep]? = nil
    var campaignApplied = false  // true when edits came from a campaign recommendation

    /// Warnings from client-side pipeline validation (displayed before save).
    var pipelineWarnings: [String] = []

    var hasPipelineEdits: Bool {
        guard let localPipeline else { return false }
        guard let serverPipeline = pricingModel?.pipeline else {
            return !localPipeline.isEmpty
        }
        guard localPipeline.count == serverPipeline.count else { return true }
        for (local, server) in zip(localPipeline, serverPipeline) {
            if local.id != server.id || local.type != server.type { return true }
        }
        return false
    }

    func editedTool(for toolId: String) -> ToolPrice? {
        localEdits[toolId]
    }

    func applyEdit(toolName: String, priceSats: Int, priceType: PriceType, priceFormula: String?, minCost: Int = 0, maxCost: Int? = nil, category: String? = nil) {
        guard let model = pricingModel, let tools = model.tools,
              var tool = tools.first(where: { $0.toolName == toolName }) else { return }
        tool.priceSats = priceSats
        tool.priceType = priceType
        tool.priceFormula = priceFormula
        tool.minCost = minCost
        tool.maxCost = maxCost
        if let category { tool.category = category }
        localEdits[tool.toolId] = tool
    }

    func resetEdit(toolId: String) {
        localEdits.removeValue(forKey: toolId)
    }

    func resetAllEdits() {
        localEdits.removeAll()
        localRemovals.removeAll()
        localPipeline = nil
        campaignApplied = false
    }

    /// Apply JSON output from the AI Pricing Consultant.
    /// Parses the consultant's campaign JSON and stages tool prices + pipeline as local edits.
    func applyConsultantJSON(_ json: String, for target: any PricingTarget) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // Apply tool prices
        if let toolDicts = obj["tools"] as? [[String: Any]] {
            for toolDict in toolDicts {
                guard let name = toolDict["tool_name"] as? String,
                      let price = toolDict["price_sats"] as? Int else { continue }
                let toolId = toolDict["tool_id"] as? String ?? name
                let category = toolDict["category"] as? String ?? "general"
                let intent = toolDict["intent"] as? String ?? ""
                let tool = ToolPrice(
                    toolId: toolId,
                    toolName: name,
                    priceSats: price,
                    priceType: .flat,
                    category: category,
                    intent: intent
                )
                localEdits[tool.toolId] = tool
            }
        }

        // Apply pipeline
        if let pipelineDicts = obj["pipeline"] as? [[String: Any]] {
            var steps: [PipelineStep] = []
            for stepDict in pipelineDicts {
                guard let type = stepDict["type"] as? String else { continue }
                var params: [String: AnyCodableValue] = [:]
                if let paramDict = stepDict["params"] as? [String: Any] {
                    for (key, value) in paramDict {
                        params[key] = anyCodableValue(from: value)
                    }
                }
                steps.append(PipelineStep.create(type: type, params: params))
            }
            localPipeline = steps
        }

        campaignApplied = true

        // Validate and repair pipeline against ConstraintCatalog
        validateAndRepairPipeline()
    }

    /// Validate pipeline steps against the ConstraintCatalog.
    /// Backfills missing required params that have catalog defaults.
    /// Populates `pipelineWarnings` for anything that can't be auto-fixed.
    func validateAndRepairPipeline() {
        guard var steps = localPipeline else {
            pipelineWarnings = []
            return
        }

        var warnings: [String] = []

        for i in steps.indices {
            let step = steps[i]
            guard let spec = ConstraintCatalog.spec(for: step.displayType) else {
                warnings.append("Step \(i + 1) (\(step.type)): unknown constraint type")
                continue
            }

            var params = step.params

            for paramSpec in spec.params {
                if params[paramSpec.name] == nil {
                    if paramSpec.required {
                        if let defaultValue = paramSpec.defaultValue {
                            // Auto-repair: backfill the catalog default
                            params[paramSpec.name] = defaultValue
                            warnings.append(
                                "Step \(i + 1) (\(step.type)): " +
                                "missing '\(paramSpec.name)' — defaulted to \(defaultValue)"
                            )
                        } else {
                            // No default available — hard error, server will reject
                            warnings.append(
                                "Step \(i + 1) (\(step.type)): " +
                                "missing required '\(paramSpec.name)' with no default — " +
                                "server will reject this pipeline"
                            )
                        }
                    }
                }
            }

            // Write repaired params back if changed
            if params.count != step.params.count {
                steps[i] = PipelineStep(
                    id: step.id,
                    type: step.type,
                    params: params
                )
            }
        }

        localPipeline = steps
        pipelineWarnings = warnings
    }

    private func anyCodableValue(from value: Any) -> AnyCodableValue {
        if let s = value as? String { return .string(s) }
        if let i = value as? Int { return .int(i) }
        if let d = value as? Double { return .double(d) }
        if let b = value as? Bool { return .bool(b) }
        if let dict = value as? [String: Any] {
            return .dictionary(dict.mapValues { anyCodableValue(from: $0) })
        }
        if let arr = value as? [Any] { return .array(arr.map { anyCodableValue(from: $0) }) }
        return .null
    }

    var hasEdits: Bool {
        !localEdits.isEmpty || !localRemovals.isEmpty || hasPipelineEdits
    }

    // MARK: - Pipeline Edits

    func beginPipelineEditing() {
        localPipeline = pricingModel?.pipeline ?? []
    }

    func addPipelineStep(type: String, params: [String: AnyCodableValue]) {
        guard localPipeline != nil else { return }
        let step = PipelineStep(id: UUID().uuidString, type: type, params: params)
        localPipeline?.append(step)
    }

    func removePipelineStep(at offsets: IndexSet) {
        localPipeline?.remove(atOffsets: offsets)
    }

    func movePipelineStep(from source: IndexSet, to destination: Int) {
        localPipeline?.move(fromOffsets: source, toOffset: destination)
    }

    func updatePipelineStepParams(stepId: String, params: [String: AnyCodableValue]) {
        guard let idx = localPipeline?.firstIndex(where: { $0.id == stepId }) else { return }
        let existing = localPipeline![idx]
        localPipeline![idx] = PipelineStep(id: existing.id, type: existing.type, params: params)
    }

    func resetPipeline() {
        localPipeline = nil
    }

    // MARK: - In-Memory Discovery Cache (5-minute TTL)

    private struct CacheEntry {
        let model: PricingModelResponse
        let memberRecord: MemberRecord?
        let versions: [String: String]?
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

        // Clear reconciliation state from previous target to prevent cross-contamination
        localEdits.removeAll()
        localRemovals.removeAll()
        localPipeline = nil
        resolvedOperatorNpub = nil

        currentOperatorNpub = target.npub

        // Check cache first
        if let entry = cache[target.npub], !entry.isExpired {
            memberRecord = entry.memberRecord
            serviceVersions = entry.versions
            loadedAt = entry.cachedAt
            state = .loaded(entry.model)
            return
        }

        await fetchPricing(for: target)
    }

    /// Bypass cache — always does a full network round-trip.
    func forceRefresh(for target: any PricingTarget) {
        cache.removeValue(forKey: target.npub)
        localEdits.removeAll()
        localRemovals.removeAll()
        localPipeline = nil
        resolvedOperatorNpub = nil
        currentOperatorNpub = nil  // allow loadPricing guard to pass
        startLoading(for: target)
    }

    private func fetchPricing(for target: any PricingTarget) async {
        // Operator with no Authority link → not registered (skip network)
        if let op = target as? Operator, op.authorityNpub == nil, op.mcpEndpointURL == nil {
            state = .notRegistered
            return
        }

        // Operator with MCP URL: check onboarding first — if not configured,
        // skip the pricing fetch entirely (it will fail anyway)
        if target is Operator, let endpoint = target.mcpEndpointURL, let url = URL(string: endpoint) {
            state = .loading(step: "Checking configuration...")
            do {
                let (_, token) = try await resolveEndpointAndToken(for: target)
                let status = try await mcpService.callGetOnboardingStatus(
                    endpointURL: url
                )
                if !status.ready {
                    // Operator isn't fully configured — show onboarding, not pricing
                    state = .registeredNotConfigured
                    return
                }
            } catch {
                // Onboarding check failed — continue to pricing fetch
                // (the operator might not have get_operator_onboarding_status yet)
            }
        }

        state = .loading(step: MCPService.ConnectionStep.resolvingOracle.rawValue)

        do {
            try await fetchPricingSteps(for: target)
        } catch is CancellationError {
            if case .loading = state { state = .idle }
        } catch let urlError as URLError where urlError.code == .cancelled {
            if case .loading = state { state = .idle }
        } catch RegistryError.operatorNotFound {
            // Check Oracle directly — operator might be registered but MCP not serving yet
            let isInRegistry = await checkOracleRegistration(npub: target.npub)
            state = isInRegistry ? .registeredNotConfigured : .notRegistered
        } catch {
            let msg = error.localizedDescription
            // "No pricing model" is not a fatal error — show empty loaded state
            if msg.contains("No pricing model") || msg.contains("not configured pricing") {
                state = .loaded(PricingModelResponse(status: "ok", modelId: nil, name: nil, isActive: nil, tools: nil, pipeline: nil))
            } else {
                let detail = "\(msg)\n\nUnderlying: \(String(describing: error))"
                TrafficLogger.shared.log(.error, label: "Load Failed: \(target.displayName)", detail: detail)
                state = .error(msg)
            }
        }
    }

    private func fetchPricingSteps(for target: any PricingTarget) async throws {
        try Task.checkCancellation()

        // Step 1: Resolve Oracle URL
        let oracleURL = try await mcpService.resolveOracleURL(forOperator: target.npub)

        try Task.checkCancellation()
        state = .loading(step: MCPService.ConnectionStep.authenticating.rawValue)

        // Step 2: Lookup via Oracle (transport handles auth)
        let member = try await mcpService.lookupOperator(npub: target.npub) { [weak self] step in
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

        // Step 3: Fetch pricing model (transport handles auth via SDK authorizer)
        let model = try await mcpService.fetchPricingModel(
            endpointURL: endpointURL
        ) { [weak self] step in
            guard !Task.isCancelled else { return }
            Task { @MainActor in
                guard !Task.isCancelled else { return }
                self?.state = .loading(step: step.rawValue)
            }
        }

        try Task.checkCancellation()

        // Merge live MCP tools so ALL tools appear in the pricing view,
        // not just those with explicit prices in the stored model.
        let enrichedModel: PricingModelResponse
        do {
            let liveTools = try await mcpService.fetchToolList(
                endpointURL: endpointURL
            )
            // Merge live MCP tools not already in the pricing model.
            // With UUID-based identity, the pricing model is authoritative.
            // Any MCP tool not in the model gets a placeholder entry for display.
            let knownNames = Set((model.tools ?? []).map(\.toolName))
            var allTools = model.tools ?? []
            for tool in liveTools {
                if !knownNames.contains(tool.name) {
                    allTools.append(ToolPrice(
                        toolName: tool.name,
                        priceSats: 0,
                        category: "free",
                        intent: tool.description ?? ""
                    ))
                }
            }
            enrichedModel = PricingModelResponse(
                status: model.status,
                modelId: model.modelId,
                name: model.name,
                isActive: model.isActive,
                tools: allTools,
                pipeline: model.pipeline,
                source: model.source
            )
        } catch {
            // Live tool fetch failed — fall back to pricing model only
            enrichedModel = model
        }

        try Task.checkCancellation()

        // Fetch service status (best-effort, non-blocking for pricing display)
        let versions = try? await mcpService.callServiceStatus(
            endpointURL: endpointURL
        )
        serviceVersions = versions

        let now = Date()
        cache[target.npub] = CacheEntry(model: enrichedModel, memberRecord: member, versions: versions, cachedAt: now)
        loadedAt = now
        state = .loaded(enrichedModel)
    }

    // MARK: - Save Pricing

    /// The npub selected for operator proof when saving pricing.
    /// Set automatically when a single operator nsec is stored, or via
    /// ``IdentityPickerView`` when multiple are available.
    var resolvedOperatorNpub: String?

    /// Set to `true` to present the identity picker sheet.
    var showingIdentityPicker = false

    /// Known operator identities (npub + display name) for the picker.
    var availableIdentities: [(npub: String, displayName: String)] = []

    func savePricing(for target: any PricingTarget) async throws {
        guard let model = pricingModel,
              let endpointString = target.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else {
            let reason = pricingModel == nil ? "No pricing model loaded"
                : target.mcpEndpointURL == nil ? "No MCP endpoint configured for \(target.displayName)"
                : "Invalid MCP endpoint URL"
            TrafficLogger.shared.log(.error, label: "Save Pricing", detail: reason)
            throw MCPError.toolCallFailed(reason)
        }

        // Pre-flight: validate and repair pipeline before sending to server
        validateAndRepairPipeline()
        let hardErrors = pipelineWarnings.filter { $0.contains("server will reject") }
        if !hardErrors.isEmpty {
            let detail = hardErrors.joined(separator: "\n")
            TrafficLogger.shared.log(.error, label: "Pipeline Validation", detail: detail)
            throw MCPError.toolCallFailed("Pipeline validation failed:\n\(detail)")
        }

        state = .loading(step: "Saving pricing...")

        // Resolve operator identity for the proof
        let operatorNpub = resolveOperatorNpub(for: target)
        if operatorNpub == nil {
            TrafficLogger.shared.log(.outbound, label: "Save Pricing", detail: "No nsec in Keychain for \(target.npub.prefix(16))… — proceeding without operator proof")
        }

        // Merge local edits into model
        let mergedModel = mergeEdits(into: model)

        _ = try await mcpService.callSetPricingModel(
            endpointURL: endpointURL,
            model: mergedModel,
            operatorNpub: operatorNpub
        )

        // Clear local edits after successful save
        localEdits.removeAll()
        localRemovals.removeAll()
        localPipeline = nil

        // Invalidate cache and reload
        cache.removeValue(forKey: target.npub)
        currentOperatorNpub = nil
        await loadPricing(for: target)
    }

    /// Determine which npub to use for the operator proof.
    ///
    /// - If ``resolvedOperatorNpub`` is already set (e.g. from picker), use it.
    /// - If the target's npub has an nsec in Keychain, use that directly.
    /// - Returns `nil` if no operator nsec is available (call proceeds without proof).
    private func resolveOperatorNpub(for target: any PricingTarget) -> String? {
        if let resolved = resolvedOperatorNpub {
            return resolved
        }
        // If the target operator's nsec is in Keychain, use it
        if KeychainService.loadNsec(forNpub: target.npub) != nil {
            return target.npub
        }
        return nil
    }

    private func mergeEdits(into model: PricingModelResponse) -> PricingModelResponse {
        var tools = model.tools ?? []

        // Replace edited tools in-place (keyed by toolId)
        if !localEdits.isEmpty {
            for (toolId, edited) in localEdits {
                if let idx = tools.firstIndex(where: { $0.toolId == toolId }) {
                    tools[idx] = edited
                } else {
                    // New tool from reconciliation — append
                    tools.append(edited)
                }
            }
        }

        // Remove stale tools (keyed by toolId)
        if !localRemovals.isEmpty {
            tools.removeAll { localRemovals.contains($0.toolId) }
        }

        let pipeline = localPipeline ?? model.pipeline
        return PricingModelResponse(
            status: model.status,
            modelId: model.modelId,
            name: model.name,
            isActive: model.isActive,
            tools: tools,
            pipeline: pipeline,
            source: model.source
        )
    }

    /// Return a preview of the model with local edits applied, for diff comparison.
    func mergedPreview(from model: PricingModelResponse) -> PricingModelResponse {
        mergeEdits(into: model)
    }

    /// Stage reconciliation results: new/changed tools into localEdits, stale tools into localRemovals.
    func applyReconciliation(suggestedTools: [ToolPrice], mismatch: MCPService.ToolMismatch) {
        for tool in suggestedTools {
            localEdits[tool.toolId] = tool
        }
        for stale in mismatch.staleTools {
            localRemovals.insert(stale.toolId)
        }
    }

    /// Resolve the MCP endpoint URL for the current target.
    /// Auth is handled by the SDK's transport authorizer — no token needed.
    func resolveEndpointAndToken(for target: any PricingTarget) async throws -> (URL, String) {
        guard let endpointString = target.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else {
            throw MCPError.connectionFailed("No MCP endpoint found for this entity")
        }
        return (endpointURL, "")
    }

    #if DEBUG
    func loadPreview(for target: any PricingTarget) {
        currentOperatorNpub = target.npub
        loadedAt = Date()
        state = .loaded(PreviewData.samplePricingModel)
    }
    #endif

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

    /// Mark an operator as registered but not yet configured.
    /// Called after successful registration when the registry cache is stale.
    func markRegisteredNotConfigured() {
        state = .registeredNotConfigured
    }

    func markNotRegistered() {
        state = .notRegistered
    }

    func retry(for target: any PricingTarget) {
        currentOperatorNpub = nil
        startLoading(for: target)
    }

    /// Check the Oracle directly for this npub's registration status.
    private func checkOracleRegistration(npub: String) async -> Bool {
        do {
            let mcpService = MCPService()
            let oracleURL = try await mcpService.resolveOracleURL(forOperator: npub)
            let response = try await mcpService.callToolGeneric(
                endpointURL: oracleURL,
                toolName: "lookup_member",
                arguments: ["npub": .string(npub)]
            )
            // If lookup returns a result with role, the operator is registered
            if let data = response.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["role"] != nil {
                return true
            }
        } catch {
            // Oracle unreachable — can't confirm either way
        }
        return false
    }

    func reset() {
        loadingTask?.cancel()
        loadingTask = nil
        state = .idle
        currentOperatorNpub = nil
        memberRecord = nil
        serviceVersions = nil
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
}

