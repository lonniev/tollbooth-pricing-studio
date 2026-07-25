import Foundation
import MCP

actor MCPService {

    /// Create a transport with the SDK's built-in OAuth authorizer.
        /// Create a transport with SDK-native OAuth. The authorizer handles 401
    /// challenges automatically — no bearer token parameter needed.
    private func makeTransport(endpoint: URL) -> HTTPClientTransport {
        HTTPClientTransport(
            endpoint: endpoint,
            streaming: true,
            sseInitializationTimeout: 30,
            authorizer: MCPAuthFactory.makeAuthorizer(for: endpoint)
        )
    }

    // MARK: - Proof Tactics

    /// Per-host slug fallback. The slug is the operator's namespace prefix
    /// ("schwab", "brain", "fermyon", …), derived from the universal
    /// `<slug>_service_status` standard tool. This is NOT a "resolve once"
    /// cache — `resolveSlug` re-derives from the live `tools/list` on every
    /// call so a renamed operator (or a reused host, e.g. a repointed
    /// Tailscale funnel) can't leave us binding proofs to a stale slug. This
    /// dictionary is consulted only when a `tools/list` fetch transiently
    /// fails, so a cold-start blip degrades gracefully instead of throwing.
    private var slugCache: [String: String] = [:]

    /// Public helper for callers that build their own proof outside
    /// `argsWithProof` (e.g. PricingDetailView's reset_pricing_model flow).
    /// Signs a kind-27235 event whose `u` tag matches the runtime tool name
    /// the wheel's `require_proof` will check.
    func signRuntimeProof(capability: String, endpointURL: URL, operatorNpub: String) async throws -> String {
        let name = await runtimeName(for: capability, endpointURL: endpointURL)
        return try OperatorProofService.createProof(toolName: name, operatorNpub: operatorNpub)
    }

    /// Join the operator's slug with a capability to produce the runtime
    /// tool name — the one identifier that crosses every server boundary
    /// (MCP wire, pricing model `tool_name`, proof u-tag, audit logs).
    /// Falls back to the bare capability if the slug can't be resolved.
    private func runtimeName(for capability: String, endpointURL: URL) async -> String {
        let slug = await resolveSlug(endpointURL: endpointURL)
        return slug.isEmpty ? capability : "\(slug)_\(capability)"
    }

    /// Resolve the operator's slug. Strategy: every Tollbooth operator
    /// exposes `<slug>_service_status` (a wheel-provided standard tool —
    /// universal and free). Find that tool in `tools/list` and take
    /// everything before `_service_status` as the slug. Robust against
    /// operators that mount multiple namespaces in one server (e.g.
    /// `<slug>_oracle_*` for delegated oracle tools).
    private func resolveSlug(endpointURL: URL) async -> String {
        let host = endpointURL.host ?? endpointURL.absoluteString
        // Always derive from the CURRENT tools/list. The proof's `u`-tag and the
        // invoked tool name must agree, and the invocation name comes straight
        // from `tools/list`; re-deriving here keeps the two in lockstep even
        // after an operator renames its slug. Fall back to the last-known slug
        // only if the live fetch fails.
        guard let tools = try? await fetchToolList(endpointURL: endpointURL) else {
            return slugCache[host] ?? ""
        }
        let marker = "_service_status"
        if let tool = tools.first(where: { $0.name.hasSuffix(marker) && $0.name.count > marker.count }) {
            let slug = String(tool.name.dropLast(marker.count))
            slugCache[host] = slug
            return slug
        }
        return slugCache[host] ?? ""
    }

    /// Build args for any tool that takes an npub + proof. Picks the best
    /// available tactic (wheel v0.23 `require_proof` accepts either form):
    ///
    /// 1. **Inline Schnorr proof** — when the App holds the nsec for
    ///    `npub`, sign a fresh kind-27235 event with the operator's
    ///    runtime tool name (`<slug>_<capability>`) in the `u` tag.
    ///    No relay round-trip, no cache dependency.
    /// 2. **Cached poison phrase** — when the App holds a `proof_token`
    ///    in Keychain for the (npub, host) pair from a prior
    ///    request_npub_proof / receive_npub_proof exchange.
    /// 3. **Empty** — let the wheel return its actionable
    ///    "proof is required" guidance.
    ///
    /// Pass `npubKey: "patron_npub"` for tools whose schema names the
    /// npub argument differently (e.g., get_patron_onboarding_status).
    /// Produce a Schnorr identity proof for an arbitrary npub against the
    /// runtime tool name resolved from `capability` at `endpointURL`.
    ///
    /// Domain-agnostic. The function knows nothing about whether the npub
    /// belongs to a patron, operator, authority, or anything else — it just
    /// signs (or looks up a cached token) for whatever npub the caller gave
    /// it. Tools that need `n` distinct proofs in a single call invoke this
    /// `n` times, once per signing identity, and assemble the args dict
    /// themselves.
    ///
    /// Resolution ladder:
    ///   1. nsec in Keychain → fresh kind-27235 Schnorr event bound to the
    ///      runtime tool name (60-second wheel-side validity window).
    ///   2. Cached proof_token in Keychain (poison phrase from a prior
    ///      `request_npub_proof` / `receive_npub_proof` round trip against
    ///      the same MCP host) → returned verbatim; wheel verifies the
    ///      cached poison-hash against the proven-npub cache.
    ///   3. Neither available → empty string. Caller decides whether to
    ///      include it; the server returns a clear error_code that
    ///      `throwIfSoftError` surfaces in the UI.
    ///
    /// Returns "" when `npub` is empty — callers can pipe it through
    /// without a guard.
    private func makeIdentityProof(
        forNpub npub: String,
        capability: String,
        endpointURL: URL
    ) async -> String {
        let toolName = await runtimeName(for: capability, endpointURL: endpointURL)
        return await makeIdentityProof(forNpub: npub, toolName: toolName, endpointURL: endpointURL)
    }

    /// Identity proof bound to an EXACT runtime tool name — the `u` tag the
    /// wheel validates against the tool being invoked.
    ///
    /// Prefer this whenever the caller already knows the real tool name (e.g.
    /// from `tools/list`). The capability-based overload re-derives the name as
    /// `<slug>_<capability>` via a second slug lookup; if that lookup transiently
    /// fails (cold start / dropped fetch) it falls back to the *bare* capability,
    /// producing a proof whose `u` tag (`check_balance`) doesn't match the real
    /// tool (`authority_check_balance`) — which the wheel rejects as
    /// `proof_invalid`. Signing for the known tool name removes that race.
    private func makeIdentityProof(
        forNpub npub: String,
        toolName: String,
        endpointURL: URL
    ) async -> String {
        guard !npub.isEmpty else { return "" }
        let host = endpointURL.host ?? endpointURL.absoluteString
        if let signed = try? OperatorProofService.createProof(toolName: toolName, operatorNpub: npub) {
            return signed
        }
        if let cached = KeychainService.loadProofToken(forPatron: npub, operator: host), !cached.isEmpty {
            return cached
        }
        return ""
    }

    /// Convenience: build args for the common case of a tool that takes the
    /// caller's `npub` and exactly one identity proof under arg name "proof".
    ///
    /// Tools that take more than one proof (e.g. wheel 0.26.0+ Authority
    /// lifecycle tools, which require both an operator proof and an
    /// Authority-side consent proof) compose `makeIdentityProof` directly
    /// at their call site and assemble the args dict explicitly. This
    /// keeps `argsWithProof` single-purpose and avoids smuggling
    /// tool-specific roles into a utility signature.
    private func argsWithProof(
        npub: String,
        capability: String,
        endpointURL: URL,
        npubKey: String = "npub",
        extra: [String: Value] = [:]
    ) async -> [String: Value] {
        var args = extra
        guard !npub.isEmpty else { return args }
        args[npubKey] = .string(npub)
        args["dpop_token"] = .string(await makeIdentityProof(forNpub: npub, capability: capability, endpointURL: endpointURL))
        return args
    }

    /// Like ``argsWithProof(npub:capability:…)`` but binds the proof to an
    /// already-known runtime tool name (from `tools/list`), avoiding the slug
    /// re-derivation race that can yield a mismatched `proof_invalid`.
    private func argsWithProof(
        npub: String,
        toolName: String,
        endpointURL: URL,
        npubKey: String = "npub",
        extra: [String: Value] = [:]
    ) async -> [String: Value] {
        var args = extra
        guard !npub.isEmpty else { return args }
        args[npubKey] = .string(npub)
        args["dpop_token"] = .string(await makeIdentityProof(forNpub: npub, toolName: toolName, endpointURL: endpointURL))
        return args
    }

    // MARK: - Soft-error detection

    /// MCP tools return *transport-level* errors via the SDK's `isError`
    /// flag, but the wheel also returns *application-level* soft errors
    /// as a normal payload: `{"success": false, "error_code": "...", "error": "..."}`.
    /// The SDK's `isError` is `false` for these — the call "succeeded" at
    /// the transport layer — so a caller that checks only `isError`
    /// silently treats the failure as success.
    ///
    /// Call this after the `isError` check, before returning the result
    /// text to the caller. If the payload is a JSON object with
    /// `success: false`, throws `MCPError.toolCallFailed(<error message>)`
    /// and logs the failure to the traffic stream so the user sees it.
    /// Non-JSON payloads pass through unchanged.
    private func throwIfSoftError(text: String, label: String) async throws {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return  // Not JSON — nothing to inspect.
        }
        guard let success = json["success"] as? Bool, success == false else {
            return  // success is true, missing, or non-bool — let the caller proceed.
        }
        let code = (json["error_code"] as? String) ?? ""
        let errMsg = (json["error"] as? String)
            ?? (code.isEmpty ? "Tool returned success=false with no error message." : code)
        // Capture string-valued sibling fields so the UI can read them off the
        // structured error. e.g. wheel's authority_consent_required returns
        // authority_npub alongside the error message.
        var extras: [String: String] = [:]
        for (key, value) in json where key != "success" && key != "error" && key != "error_code" {
            if let s = value as? String { extras[key] = s }
        }
        await traffic(.error, label: "\(label) Error", detail: "[\(code)] \(errMsg)")
        throw MCPError.structuredError(code: code, message: errMsg, extras: extras)
    }

    // MARK: - Npub Proof Exchange

    /// Request a poison-keyed npub ownership proof from the MCP.
    /// Returns the proof_token (poison phrase) that the application must remember.
    /// The wheel's response to ``request_npub_proof``.
    ///
    /// ``rendezvousRelay`` is the per-conversation relay pin — the
    /// responder MUST publish their signed reply DM on this exact
    /// relay so the courier's listener finds it. Empty when the wheel
    /// predates v0.39.0 (pre-pinning protocol).
    struct NpubProofChallenge: Sendable {
        let proofToken: String
        let rendezvousRelay: String
    }

    func callRequestNpubProof(endpointURL: URL, patronNpub: String) async throws -> NpubProofChallenge {
        let result = try await callToolGeneric(
            endpointURL: endpointURL,
            toolName: "request_npub_proof",
            arguments: ["patron_npub": .string(patronNpub)]
        )
        guard let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["success"] as? Bool == true,
              let proofToken = json["dpop_token"] as? String else {
            throw MCPError.toolCallFailed("request_npub_proof failed: \(result)")
        }
        let rendezvousRelay = json["rendezvous_relay"] as? String ?? ""
        return NpubProofChallenge(proofToken: proofToken, rendezvousRelay: rendezvousRelay)
    }

    /// Receive and confirm a poison-keyed npub ownership proof.
    /// Returns the proof_token and stores it in Keychain for the patron+operator pair.
    ///
    /// - Parameter poison: the `proof_token` returned by ``callRequestNpubProof``.
    ///   The wheel's deterministic retrieve contract requires it to resolve the
    ///   pinned rendezvous relay for this exact challenge.
    func callReceiveNpubProof(endpointURL: URL, patronNpub: String, poison: String) async throws -> String {
        let result = try await callToolGeneric(
            endpointURL: endpointURL,
            toolName: "receive_npub_proof",
            arguments: [
                "patron_npub": .string(patronNpub),
                "dpop_token": .string(poison),
            ]
        )
        guard let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["success"] as? Bool == true,
              let proofToken = json["dpop_token"] as? String else {
            throw MCPError.toolCallFailed("receive_npub_proof failed: \(result)")
        }
        // Persist to Keychain for this patron+operator
        let host = endpointURL.host ?? endpointURL.absoluteString
        try KeychainService.saveProofToken(proofToken, forPatron: patronNpub, operator: host)
        return proofToken
    }

    // MARK: - Free Tools

    struct EffectivePrice {
        let baseCostSats: Int
        let effectiveCostSats: Int
    }

    func callCheckPrice(endpointURL: URL, toolId: String, patronNpub: String) async throws -> EffectivePrice {
        let result = try await callToolGeneric(
            endpointURL: endpointURL,
            toolName: "check_price",
            arguments: [
                "tool_id": .string(toolId),
                "npub": .string(patronNpub),
            ]
        )
        guard let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["success"] as? Bool == true else {
            throw MCPError.toolCallFailed("check_price failed")
        }
        let base = json["base_cost_api_sats"] as? Int ?? 0
        let effective = json["effective_cost_api_sats"] as? Int ?? base
        return EffectivePrice(
            baseCostSats: base,
            effectiveCostSats: effective
        )
    }

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
        let oracleURL = try await RegistryService.resolveOracleURL(forOperator: npub)

        onStep(.lookingUpOperator)
        return try await callOracleLookup(oracleURL: oracleURL, npub: npub)
    }

    func resolveOracleURL(forOperator npub: String) async throws -> URL {
        try await RegistryService.resolveOracleURL(forOperator: npub)
    }

    func fetchPricingModel(
        endpointURL: URL,
        onStep: @Sendable (ConnectionStep) -> Void
    ) async throws -> PricingModelResponse {
        onStep(.connectingToOperator)

        onStep(.fetchingPricing)

        // Load the operator's pricing model — never synthesize or guess
        if let stored = try? await callGetPricingModel(endpointURL: endpointURL),
           stored.tools != nil {
            var result = stored
            result.source = .stored
            onStep(.done)
            return result
        }

        // No pricing model available — operator is out of service
        onStep(.done)
        throw MCPError.toolCallFailed("No pricing model available. This operator has not configured pricing and is out of service.")
    }

    // MARK: - Oracle Lookup

    private func callOracleLookup(oracleURL: URL, npub: String) async throws -> MemberRecord {
        await traffic(.outbound, label: "Oracle Connect", detail: "SSE → \(oracleURL.absoluteString) (Bearer auth)")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: oracleURL)
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

        let preview = String(text.prefix(4000))
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
        patronNpub: String = ""
    ) async throws -> PatronAccountViewModel.BalanceResult {
        await traffic(.outbound, label: "Balance Check", detail: "SSE → \(endpointURL.absoluteString)")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        guard let balanceTool = allTools.first(where: { $0.name.contains("check_balance") }) else {
            await traffic(.error, label: "Balance Check", detail: "No check_balance tool found")
            throw MCPError.toolCallFailed("No check_balance tool found")
        }

        // Bind the proof to the actual balance tool we resolved from tools/list
        // (e.g. authority_check_balance), not a re-derived <slug>_check_balance —
        // the latter can mis-resolve on a cold endpoint and trip proof_invalid.
        let args = await argsWithProof(npub: patronNpub, toolName: balanceTool.name, endpointURL: endpointURL)
        let (content, isError) = try await client.callTool(name: balanceTool.name, arguments: args)

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            await traffic(.error, label: "Balance Check Error", detail: errorText)
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first,
              let data = text.data(using: .utf8) else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "Balance Check", detail: String(text.prefix(4000)))
        try await throwIfSoftError(text: text, label: "Balance Check")

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

        let balance = (balanceDict["balance_api_sats"] as? Int) ?? 0
        let deposited = (balanceDict["total_deposited_api_sats"] as? Int) ?? 0
        let consumed = (balanceDict["total_consumed_api_sats"] as? Int) ?? 0
        let expired = (balanceDict["total_expired_api_sats"] as? Int) ?? 0
        let tranches = (balanceDict["active_tranches"] as? Int) ?? 0
        let expiring24h = (balanceDict["expiring_within_24h_sats"] as? Int) ?? 0

        func parseFlexibleDate(_ str: String) -> Date? {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            // ISO8601 with fractional seconds
            let iso1 = ISO8601DateFormatter()
            iso1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso1.date(from: trimmed) { return d }
            // ISO8601 standard
            let iso2 = ISO8601DateFormatter()
            iso2.formatOptions = [.withInternetDateTime]
            if let d = iso2.date(from: trimmed) { return d }
            // Common date formats
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            for fmt in [
                "yyyy-MM-dd'T'HH:mm:ss",
                "yyyy-MM-dd HH:mm:ss Z",
                "yyyy-MM-dd HH:mm:ss",
                "yyyy-MM-dd",
                "MM-dd-yyyy",
                "MM/dd/yyyy",
                "M-d",
                "MMM d, yyyy",
                "MMMM d, yyyy",
            ] {
                df.dateFormat = fmt
                if let d = df.date(from: trimmed) { return d }
            }
            // Natural language: "tomorrow", "Wednesday", etc.
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
            if let match = detector?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) {
                return match.date
            }
            return nil
        }

        var nextExpiration: Date? = nil
        if let isoStr = balanceDict["next_expiration_iso"] as? String {
            nextExpiration = parseFlexibleDate(isoStr)
        }

        var trancheDetails: [PatronAccountViewModel.TrancheDetail] = []
        if let trancheArray = balanceDict["tranches"] as? [[String: Any]] {
            for (index, t) in trancheArray.enumerated() {
                let amount = (t["amount_sats"] as? Int) ?? 0
                let remaining = (t["remaining_sats"] as? Int) ?? amount
                let expiresAt = (t["expires_at"] as? String).flatMap { parseFlexibleDate($0) }
                let createdAt = (t["created_at"] as? String).flatMap { parseFlexibleDate($0) }
                let id = (t["id"] as? String) ?? "\(index)"
                trancheDetails.append(PatronAccountViewModel.TrancheDetail(
                    id: id,
                    amountSats: amount,
                    remainingSats: remaining,
                    expiresAt: expiresAt,
                    createdAt: createdAt
                ))
            }
        }

        let pendingCount = (balanceDict["pending_invoices"] as? Int) ?? 0
        let pendingIds = (balanceDict["pending_invoice_ids"] as? [String]) ?? []

        var invoiceSummary: PatronAccountViewModel.InvoiceSummary?
        if let summary = balanceDict["invoice_summary"] as? [String: Any] {
            invoiceSummary = PatronAccountViewModel.InvoiceSummary(
                totalInvoices: (summary["total_invoices"] as? Int) ?? 0,
                settledCount: (summary["settled_count"] as? Int) ?? 0,
                pendingCount: (summary["pending_count"] as? Int) ?? 0,
                totalRealSats: (summary["total_real_sats"] as? Int) ?? 0,
                totalApiSatsCredited: (summary["total_api_sats_credited"] as? Int) ?? 0
            )
        }

        return PatronAccountViewModel.BalanceResult(
            balanceApiSats: balance,
            totalDeposited: deposited,
            totalConsumed: consumed,
            totalExpired: expired,
            activeTranches: tranches,
            expiringWithin24h: expiring24h,
            nextExpiration: nextExpiration,
            tranches: trancheDetails,
            pendingInvoiceCount: pendingCount,
            pendingInvoiceIds: pendingIds,
            invoiceSummary: invoiceSummary
        )
    }

    // MARK: - Account Statement

    struct InvoiceLineItem: Sendable, Identifiable {
        let id: String        // invoice_id
        let status: String    // Pending | Settled | Expired | Invalid
        let amountSats: Int
        let apiSatsCredited: Int
        let multiplier: Int
        let createdAt: Date?
        let settledAt: Date?
    }

    struct AccountSummary: Sendable, Equatable {
        let balanceApiSats: Int
        let totalDepositedApiSats: Int
        let totalConsumedApiSats: Int
        let totalExpiredApiSats: Int
    }

    struct ActiveTranche: Sendable, Identifiable {
        let id: String           // composite — invoice_id + granted_at, stable enough for ForEach
        let invoiceId: String
        let originalSats: Int
        let remainingSats: Int
        let grantedAt: Date?
        let expiresAt: Date?
    }

    struct ToolUsageStat: Sendable, Identifiable {
        let id: String           // tool name
        var tool: String { id }
        let calls: Int
        let apiSats: Int
    }

    struct DailyUsageStat: Sendable, Identifiable {
        let id: String           // ISO date
        var date: String { id }
        let totalCalls: Int
        let totalApiSats: Int
    }

    struct AccountStatementResult: Sendable {
        let invoiceItems: [InvoiceLineItem]
        let summary: AccountSummary?
        let activeTranches: [ActiveTranche]
        let toolUsage: [ToolUsageStat]
        let dailyUsage: [DailyUsageStat]
        let generatedAt: Date?
        let statementPeriodDays: Int?
    }

    func callAccountStatement(
        endpointURL: URL,
        patronNpub: String = ""
    ) async throws -> AccountStatementResult {
        await traffic(.outbound, label: "Account Statement", detail: "SSE → \(endpointURL.absoluteString)")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        // Match account_statement but not account_statement_infographic
        guard let tool = allTools.first(where: {
            $0.name.contains("account_statement") && !$0.name.contains("infographic")
        }) else {
            await traffic(.error, label: "Account Statement", detail: "No account_statement tool found")
            throw MCPError.toolCallFailed("No account_statement tool found")
        }

        let args = await argsWithProof(npub: patronNpub, toolName: tool.name, endpointURL: endpointURL)
        let (content, isError) = try await client.callTool(name: tool.name, arguments: args)

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            await traffic(.error, label: "Account Statement Error", detail: errorText)
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first,
              let data = text.data(using: .utf8) else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "Account Statement", detail: String(text.prefix(4000)))
        try await throwIfSoftError(text: text, label: "Account Statement")

        return try parseAccountStatementResponse(data)
    }

    private func parseAccountStatementResponse(_ data: Data) throws -> AccountStatementResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.invalidResponse
        }

        let root: [String: Any]
        if let result = json["result"] as? [String: Any] {
            root = result
        } else {
            root = json
        }

        let rawItems = (root["purchase_history"] as? [[String: Any]]) ?? []

        let items: [InvoiceLineItem] = rawItems.map { dict in
            let invoiceId = dict["invoice_id"] as? String ?? ""
            let status = dict["status"] as? String ?? "Unknown"
            let amountSats = (dict["amount_sats"] as? Int) ?? Int(dict["amount_sats"] as? String ?? "") ?? 0
            let apiSats = (dict["api_sats_credited"] as? Int) ?? Int(dict["api_sats_credited"] as? String ?? "") ?? 0
            let multiplier = (dict["multiplier"] as? Int) ?? Int(dict["multiplier"] as? String ?? "") ?? 1
            let rawCreatedAt = (dict["created_at"] as? String).flatMap { parseISO8601($0) }
            let settledAt = (dict["settled_at"] as? String).flatMap { parseISO8601($0) }
            // Fall back to settled_at when created_at is missing or empty
            let createdAt = rawCreatedAt ?? settledAt

            return InvoiceLineItem(
                id: invoiceId,
                status: status,
                amountSats: amountSats,
                apiSatsCredited: apiSats,
                multiplier: multiplier,
                createdAt: createdAt,
                settledAt: settledAt
            )
        }

        // -- Account summary ------------------------------------------------
        var summary: AccountSummary?
        if let s = root["account_summary"] as? [String: Any] {
            summary = AccountSummary(
                balanceApiSats: Self.intField(s, "balance_api_sats"),
                totalDepositedApiSats: Self.intField(s, "total_deposited_api_sats"),
                totalConsumedApiSats: Self.intField(s, "total_consumed_api_sats"),
                totalExpiredApiSats: Self.intField(s, "total_expired_api_sats")
            )
        }

        // -- Active tranches ------------------------------------------------
        let rawTranches = (root["active_tranches"] as? [[String: Any]]) ?? []
        let tranches: [ActiveTranche] = rawTranches.enumerated().map { idx, dict in
            let invoiceId = dict["invoice_id"] as? String ?? "tranche_\(idx)"
            let original = Self.intField(dict, "original_sats")
            let remaining = Self.intField(dict, "remaining_sats")
            let granted = (dict["granted_at"] as? String).flatMap { parseISO8601($0) }
            let expires = (dict["expires_at"] as? String).flatMap { parseISO8601($0) }
            let id = "\(invoiceId)#\(dict["granted_at"] as? String ?? String(idx))"
            return ActiveTranche(
                id: id,
                invoiceId: invoiceId,
                originalSats: original,
                remainingSats: remaining,
                grantedAt: granted,
                expiresAt: expires
            )
        }

        // -- All-time tool usage --------------------------------------------
        let rawTools = (root["tool_usage_all_time"] as? [[String: Any]]) ?? []
        let toolUsage: [ToolUsageStat] = rawTools.compactMap { dict in
            guard let name = dict["tool"] as? String, !name.isEmpty else { return nil }
            return ToolUsageStat(
                id: name,
                calls: Self.intField(dict, "calls"),
                apiSats: Self.intField(dict, "api_sats")
            )
        }

        // -- Daily usage ----------------------------------------------------
        let rawDays = (root["daily_usage"] as? [[String: Any]]) ?? []
        let dailyUsage: [DailyUsageStat] = rawDays.compactMap { dict in
            guard let date = dict["date"] as? String, !date.isEmpty else { return nil }
            return DailyUsageStat(
                id: date,
                totalCalls: Self.intField(dict, "total_calls"),
                totalApiSats: Self.intField(dict, "total_api_sats")
            )
        }

        let generatedAt = (root["generated_at"] as? String).flatMap { parseISO8601($0) }
        let period = root["statement_period_days"] as? Int

        return AccountStatementResult(
            invoiceItems: items,
            summary: summary,
            activeTranches: tranches,
            toolUsage: toolUsage,
            dailyUsage: dailyUsage,
            generatedAt: generatedAt,
            statementPeriodDays: period
        )
    }

    /// Coerce a JSON value to Int. Accepts Int, Double, or numeric String.
    private static func intField(_ dict: [String: Any], _ key: String) -> Int {
        if let v = dict[key] as? Int { return v }
        if let v = dict[key] as? Double { return Int(v) }
        if let s = dict[key] as? String, let v = Int(s) { return v }
        return 0
    }

    private func parseISO8601(_ str: String) -> Date? {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)

        // ISO8601DateFormatter handles up to milliseconds (3 fractional digits).
        // Python's .isoformat() emits microseconds (6 digits), which the
        // system formatter silently rejects. Truncate to 3 digits so the
        // standard parser succeeds.
        let normalized = Self.truncateMicroseconds(trimmed)

        let fmt1 = ISO8601DateFormatter()
        fmt1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt1.date(from: normalized) { return d }
        let fmt2 = ISO8601DateFormatter()
        fmt2.formatOptions = [.withInternetDateTime]
        if let d = fmt2.date(from: normalized) { return d }
        // Bare datetime without timezone
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let d = df.date(from: normalized) { return d }
        // Space-separated (e.g. "2026-04-22 14:30:00+00:00")
        df.dateFormat = "yyyy-MM-dd HH:mm:ssxxx"
        return df.date(from: normalized)
    }

    /// Truncate microsecond fractional seconds (.123456) to milliseconds (.123)
    /// so ISO8601DateFormatter can parse them.
    private static func truncateMicroseconds(_ iso: String) -> String {
        // Match ".NNNNNN" (4-6 fractional digits) before a timezone suffix or EOL
        guard let range = iso.range(of: #"\.\d{4,6}"#, options: .regularExpression) else {
            return iso
        }
        let frac = iso[range]            // e.g. ".123456"
        let millis = frac.prefix(4)      // e.g. ".123"
        return iso.replacingCharacters(in: range, with: String(millis))
    }

    // MARK: - Account Statement Infographic

    struct InfographicResult: Sendable {
        let svgContent: String?
        let pngBase64: String?
        let generatedAt: String?
    }

    /// Call account_statement_infographic on an operator's MCP endpoint.
    /// Returns SVG or PNG data for a rich balance visualization.
    func callAccountStatementInfographic(
        endpointURL: URL,
        patronNpub: String = ""
    ) async throws -> InfographicResult {
        await traffic(.outbound, label: "Statement Infographic", detail: "SSE → \(endpointURL.absoluteString)")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        guard let infoTool = allTools.first(where: { $0.name.contains("account_statement_infographic") }) else {
            await traffic(.inbound, label: "Statement Infographic", detail: "Tool not found on this operator")
            throw MCPError.toolCallFailed("No account_statement_infographic tool found")
        }

        let args = await argsWithProof(npub: patronNpub, toolName: infoTool.name, endpointURL: endpointURL)
        let (content, isError) = try await client.callTool(name: infoTool.name, arguments: args)

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            await traffic(.error, label: "Statement Infographic Error", detail: errorText)
            throw MCPError.toolCallFailed(errorText)
        }

        // Check for image content first (PNG/JPEG)
        for item in content {
            if case .image(let data, let mimeType, _, _) = item {
                await traffic(.inbound, label: "Statement Infographic", detail: "Image received: \(mimeType)")
                return InfographicResult(svgContent: nil, pngBase64: data, generatedAt: nil)
            }
        }

        // Fall back to text content (SVG or JSON wrapper)
        guard let text = content.compactMap({ extractText($0) }).first else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "Statement Infographic", detail: String(text.prefix(4000)))
        try await throwIfSoftError(text: text, label: "Statement Infographic")

        // Try JSON with svg/png fields first (most common response format)
        // Must check JSON before raw SVG since JSON may contain embedded <svg
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let responseDict: [String: Any]
            if let result = json["result"] as? [String: Any] {
                responseDict = result
            } else {
                responseDict = json
            }
            return InfographicResult(
                svgContent: responseDict["svg"] as? String,
                pngBase64: responseDict["png_base64"] as? String ?? responseDict["image_base64"] as? String,
                generatedAt: responseDict["generated_at"] as? String
            )
        }

        // Fall back to raw SVG if text starts with <svg or <?xml
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<svg") || trimmed.hasPrefix("<?xml") {
            return InfographicResult(svgContent: text, pngBase64: nil, generatedAt: nil)
        }

        throw MCPError.invalidResponse
    }

    // MARK: - Purchase Credits

    struct PurchaseResult: Sendable {
        let invoiceId: String
        let checkoutLink: String
        let lightningInvoice: String?
        let amountSats: Int
    }

    func callPurchaseCredits(
        endpointURL: URL,
        amountSats: Int,
        patronNpub: String = ""
    ) async throws -> PurchaseResult {
        await traffic(.outbound, label: "Purchase Credits", detail: "SSE → \(endpointURL.absoluteString) amount=\(amountSats)")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        guard let purchaseTool = allTools.first(where: { $0.name.contains("purchase_credits") }) else {
            await traffic(.error, label: "Purchase Credits", detail: "No purchase_credits tool found")
            throw MCPError.toolCallFailed("No purchase_credits tool found")
        }

        let (content, isError) = try await client.callTool(
            name: purchaseTool.name,
            arguments: await argsWithProof(npub: patronNpub, capability: "purchase_credits", endpointURL: endpointURL, extra: ["amount_sats": .int(amountSats)])
        )

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            await traffic(.error, label: "Purchase Credits Error", detail: errorText)
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first,
              let data = text.data(using: .utf8) else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "Purchase Credits", detail: String(text.prefix(4000)))
        try await throwIfSoftError(text: text, label: "Purchase Credits")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.invalidResponse
        }

        let responseDict: [String: Any]
        if let result = json["result"] as? [String: Any] {
            responseDict = result
        } else {
            responseDict = json
        }

        let invoiceId = (responseDict["invoice_id"] as? String)
            ?? (responseDict["invoiceId"] as? String)
            ?? ""
        let checkoutLink = (responseDict["checkout_link"] as? String)
            ?? (responseDict["checkoutLink"] as? String)
            ?? ""
        let bolt11 = (responseDict["lightning_invoice"] as? String)
            ?? (responseDict["lightningInvoice"] as? String)

        return PurchaseResult(
            invoiceId: invoiceId,
            checkoutLink: checkoutLink,
            lightningInvoice: bolt11,
            amountSats: amountSats
        )
    }

    // MARK: - Check Payment

    struct CheckPaymentResult: Sendable {
        let invoiceId: String
        let status: String
        let creditsGranted: Int
        let balanceApiSats: Int
        let message: String
    }

    /// Result of a successful restore_credits call.
    ///
    /// `source` is `"vault_record"` when the wheel found an existing settled
    /// invoice in the operator's ledger (idempotent re-credit), or `"btcpay"`
    /// when the wheel had to ask BTCPay for the truth — the cold-start
    /// recovery case the 0.30.0+ guards exist for. `persisted: true` is
    /// guaranteed by 0.30.0's `_vault_unavailable` refusal; older operators
    /// could return `persisted: false` (we propagate honestly).
    struct RestoreCreditsResult: Sendable {
        let invoiceId: String
        let source: String          // "vault_record" | "btcpay"
        let amountSats: Int
        let creditsGranted: Int
        let balanceApiSats: Int
        let persisted: Bool
        let message: String
    }

    /// Re-issue a credit grant for a known invoice ID that didn't land
    /// during the original `check_payment` flow.
    ///
    /// **Operator-restricted since wheel 0.36.0**: the proof MUST be
    /// signed by the operator's nsec, not the patron's. The patron is
    /// identified by `patronNpub` (a plain argument); the operator
    /// authorizes the grant by signing the proof. The caller must have
    /// the operator's nsec in this device's Keychain.
    ///
    /// Common recovery cases:
    /// - Operator support escalation — patron emailed "I paid invoice XYZ,
    ///   never got credit." The operator pastes the patron's npub + invoice
    ///   ID; this method signs the operator's proof and credits the patron.
    /// - Operator's vault was cold-start-unavailable when check_payment ran
    ///   (pre-0.30.0 silently dropped the credit; 0.30.0+ refused honestly).
    /// - Patron paid the Lightning invoice but closed the Top-Off sheet
    ///   before clicking Check Payment, never resumed via the operator.
    ///
    /// Soft errors propagate as `MCPError.structuredError`:
    /// - `operator_nsec_missing` (this method) — nsec not in Keychain.
    /// - `operator_proof_required` / `operator_proof_invalid` (wheel) —
    ///   proof not signed by the operator's npub or doesn't verify.
    /// - `vault_unavailable` — wheel's Neon write/read failed; retry.
    func callRestoreCredits(
        endpointURL: URL,
        invoiceId: String,
        patronNpub: String,
        operatorNpub: String
    ) async throws -> RestoreCreditsResult {
        await traffic(.outbound, label: "Restore Credits", detail: "SSE → \(endpointURL.absoluteString) invoice=\(invoiceId) patron=\(patronNpub.prefix(16))… operator=\(operatorNpub.prefix(16))…")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        guard let restoreTool = allTools.first(where: { $0.name.contains("restore_credits") }) else {
            await traffic(.error, label: "Restore Credits", detail: "No restore_credits tool found")
            throw MCPError.toolCallFailed("This operator's wheel doesn't expose restore_credits (upgrade to 0.31.0+).")
        }

        // Sign with the OPERATOR's nsec. patron_npub is a plain tool
        // argument that identifies whose ledger receives the credit;
        // the operator's proof is the gate (wheel 0.36.0+).
        let proof = (try? await signRuntimeProof(
            capability: "restore_credits",
            endpointURL: endpointURL,
            operatorNpub: operatorNpub
        )) ?? ""
        if proof.isEmpty {
            throw MCPError.structuredError(
                code: "operator_nsec_missing",
                message: "Operator nsec for \(operatorNpub.prefix(16))… is not in this device's Keychain. Only the operator can restore credits; the patron must escalate to the operator's support.",
                extras: ["operator_npub": operatorNpub]
            )
        }
        let args: [String: Value] = [
            "invoice_id": .string(invoiceId),
            "patron_npub": .string(patronNpub),
            "dpop_token": .string(proof),
        ]
        let (content, isError) = try await client.callTool(name: restoreTool.name, arguments: args)

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            await traffic(.error, label: "Restore Credits Error", detail: errorText)
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first,
              let data = text.data(using: .utf8) else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "Restore Credits", detail: String(text.prefix(4000)))
        try await throwIfSoftError(text: text, label: "Restore Credits")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.invalidResponse
        }
        let dict = (json["result"] as? [String: Any]) ?? json

        return RestoreCreditsResult(
            invoiceId: (dict["invoice_id"] as? String) ?? invoiceId,
            source: (dict["source"] as? String) ?? "",
            amountSats: (dict["amount_sats"] as? Int) ?? 0,
            creditsGranted: (dict["credits_granted"] as? Int) ?? 0,
            balanceApiSats: (dict["balance_api_sats"] as? Int) ?? 0,
            persisted: (dict["persisted"] as? Bool) ?? false,
            message: (dict["message"] as? String) ?? ""
        )
    }

    func callCheckPayment(
        endpointURL: URL,
        invoiceId: String,
        npub: String = ""
    ) async throws -> CheckPaymentResult {
        await traffic(.outbound, label: "Check Payment", detail: "SSE → \(endpointURL.absoluteString) invoice=\(invoiceId)")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        guard let paymentTool = allTools.first(where: { $0.name.contains("check_payment") }) else {
            await traffic(.error, label: "Check Payment", detail: "No check_payment tool found")
            throw MCPError.toolCallFailed("No check_payment tool found")
        }

        let (content, isError) = try await client.callTool(
            name: paymentTool.name,
            arguments: await argsWithProof(npub: npub, capability: "check_payment", endpointURL: endpointURL, extra: ["invoice_id": .string(invoiceId)])
        )

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            await traffic(.error, label: "Check Payment Error", detail: errorText)
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first,
              let data = text.data(using: .utf8) else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "Check Payment", detail: String(text.prefix(4000)))

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.invalidResponse
        }

        let responseDict: [String: Any]
        if let result = json["result"] as? [String: Any] {
            responseDict = result
        } else {
            responseDict = json
        }

        return CheckPaymentResult(
            invoiceId: (responseDict["invoice_id"] as? String) ?? invoiceId,
            status: (responseDict["status"] as? String) ?? "Unknown",
            creditsGranted: (responseDict["credits_granted"] as? Int) ?? 0,
            balanceApiSats: (responseDict["balance_api_sats"] as? Int) ?? 0,
            message: (responseDict["message"] as? String) ?? ""
        )
    }

    // MARK: - Get Pricing Model (stored)

    /// Call get_pricing_model on an operator's MCP endpoint.
    /// Returns nil if the tool is not found (operator doesn't support stored pricing).
    /// Single source of truth for retrieving + parsing the pricing model.
    /// All consumers — the Pricing View and the AI consultant — must
    /// flow through this function so what Claude sees equals what the
    /// human can see. If a field isn't expressible in PricingModelResponse,
    /// neither view receives it.
    func callGetPricingModel(
        endpointURL: URL
    ) async throws -> PricingModelResponse? {
        await traffic(.outbound, label: "Get Pricing Model", detail: "→ \(endpointURL.absoluteString)")

        let text: String
        do {
            text = try await _connectAndCall(
                endpointURL: endpointURL,
                toolName: "get_pricing_model",
                arguments: [:]
            )
        } catch MCPError.toolCallFailed(let msg) where msg.contains("not found") {
            await traffic(.inbound, label: "Get Pricing Model", detail: "Tool not found — operator doesn't support stored pricing")
            return nil
        }

        await traffic(.inbound, label: "Get Pricing Model", detail: String(text.prefix(4000)))

        guard let data = text.data(using: .utf8) else {
            throw MCPError.invalidResponse
        }
        let response = try JSONDecoder().decode(PricingModelResponse.self, from: data)
        guard response.tools != nil else { return nil }
        return response
    }

    // MARK: - Set Pricing Model

    /// Payload for serializing a pricing model to the format expected by
    /// set_pricing_model.  Per tollbooth-dpyc 0.40.0+: there is no
    /// operator-wide pipeline — each ``ToolPrice.chain`` carries that
    /// tool's ordered constraint chain.
    private struct SetPricingPayload: Encodable {
        let modelId: String?
        let name: String
        let tools: [ToolPrice]
        let trancheLifetime: TrancheLifetime?

        enum CodingKeys: String, CodingKey {
            case modelId = "model_id"
            case name, tools
            case trancheLifetime = "tranche_lifetime"
        }
    }

    /// Call set_pricing_model on an operator's MCP endpoint.
    /// Returns the model_id of the created/updated model.
    ///
    /// - Parameters:
    ///   - endpointURL: The operator's MCP SSE endpoint.
        ///   - model: The pricing model to save.
    ///   - operatorNpub: If provided, generates a kind-27235 operator proof
    ///     so a patron session can prove operator authority.
    func callSetPricingModel(
        endpointURL: URL,
        model: PricingModelResponse,
        operatorNpub: String? = nil
    ) async throws -> String {
        await traffic(.outbound, label: "Set Pricing Model", detail: "SSE → \(endpointURL.absoluteString)")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        // Match the EXACT `<slug>_set_pricing_model` — the same runtime name the
        // proof is signed for. `.contains("set_pricing_model")` also matches
        // `<slug>_reset_pricing_model` (it *contains* "set_pricing_model"), and when
        // tools/list is sorted (reset < set) `.first` picks RESET — invoking reset
        // with a set-bound proof → proof_invalid. `_set_pricing_model` (leading `_`)
        // excludes reset, which ends in `…eset_pricing_model`.
        guard let setTool = allTools.first(where: {
            $0.name == "set_pricing_model" || $0.name.hasSuffix("_set_pricing_model")
        }) else {
            await traffic(.error, label: "Set Pricing Model", detail: "No set_pricing_model tool found")
            throw MCPError.toolCallFailed("No set_pricing_model tool found")
        }

        // Build the model_json payload
        let effectiveModelId = (model.modelId != "synthesized") ? model.modelId : nil
        let payload = SetPricingPayload(
            modelId: effectiveModelId,
            name: model.name ?? "Pricing Model",
            tools: model.tools ?? [],
            trancheLifetime: model.trancheLifetime
        )
        let jsonData = try JSONEncoder().encode(payload)

        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        // Pass operator Schnorr proof as a separate parameter (restricted tool)
        var arguments: [String: Value] = ["model_json": .string(jsonString)]
        if let npub = operatorNpub {
            let proof = (try? await signRuntimeProof(
                capability: "set_pricing_model",
                endpointURL: endpointURL,
                operatorNpub: npub
            )) ?? ""
            if !proof.isEmpty {
                arguments["dpop_token"] = .string(proof)
            }
            await traffic(.outbound, label: "Proof", detail: "Signed kind-27235 for \(npub.prefix(16))…")
        }

        await traffic(.outbound, label: "callTool: \(setTool.name)", detail: "model_json: \(String(jsonString.prefix(4000)))")

        let (content, isError) = try await client.callTool(
            name: setTool.name,
            arguments: arguments
        )

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            await traffic(.error, label: "Set Pricing Model Error", detail: errorText)
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first,
              let data = text.data(using: .utf8) else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "Set Pricing Model", detail: String(text.prefix(4000)))
        try await throwIfSoftError(text: text, label: "Set Pricing Model")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.invalidResponse
        }

        guard let status = json["status"] as? String, status == "ok" else {
            let error = json["error"] as? String ?? "Unknown error"
            throw MCPError.toolCallFailed(error)
        }

        return (json["model_id"] as? String) ?? ""
    }

    // MARK: - Service Status

    /// Call `service_status` on an operator's MCP endpoint.
    /// Returns the versions dictionary (package → version string) or nil if the tool isn't found.
    func callServiceStatus(
        endpointURL: URL
    ) async throws -> [String: String]? {
        await traffic(.outbound, label: "Service Status", detail: "SSE → \(endpointURL.absoluteString)")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        guard let statusTool = allTools.first(where: { $0.name.contains("service_status") }) else {
            await traffic(.inbound, label: "Service Status", detail: "Tool not found on this endpoint")
            return nil
        }

        let (content, isError) = try await client.callTool(name: statusTool.name, arguments: [:])

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            await traffic(.error, label: "Service Status Error", detail: errorText)
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first,
              let data = text.data(using: .utf8) else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "Service Status", detail: String(text.prefix(4000)))

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.invalidResponse
        }

        // Build versions dict from top-level fields + build_info
        var versions: [String: String] = [:]
        if let s = json["slug"] as? String {
            versions["slug"] = s
        }
        if let v = json["version"] as? String, v != "unknown" {
            versions["service"] = v
        }
        if let v = json["tollbooth_dpyc_version"] as? String, v != "unknown" {
            versions["tollbooth_dpyc"] = v
        }
        // The Spin/WASI host (tollbooth-wasmcp) version, reported alongside the wheel
        // by operators built on the SpinOperatorHost adapter.
        if let v = json["tollbooth_wasmcp_version"] as? String, v != "unknown" {
            versions["tollbooth_wasmcp"] = v
        }
        if let buildInfo = json["build_info"] as? [String: String] {
            if let sha = buildInfo["fastmcp_cloud_git_commit_sha"] {
                versions["git_commit"] = String(sha.prefix(8))
            }
            if let repo = buildInfo["fastmcp_cloud_git_repo"] {
                let repoName = repo.components(separatedBy: "/").last ?? repo
                versions["repo"] = repoName
            }
        }
        // Legacy: also check for old-style "versions" dict
        if let legacy = json["versions"] as? [String: String] {
            for (k, v) in legacy { versions[k] = v }
        }

        return versions.isEmpty ? nil : versions
    }

    // MARK: - Register Authority Npub (Claim)

    /// Call `register_authority_npub` on an Authority's MCP endpoint to initiate
    /// the adoption protocol. Returns the text response from the tool.
    func callRegisterAuthorityNpub(
        endpointURL: URL,
        candidateNpub: String
    ) async throws -> String {
        await traffic(.outbound, label: "Register Authority Npub", detail: "SSE → \(endpointURL.absoluteString) candidate=\(candidateNpub)")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        guard let registerTool = allTools.first(where: { $0.name.contains("register_authority_npub") }) else {
            await traffic(.error, label: "Register Authority Npub", detail: "No register_authority_npub tool found")
            throw MCPError.toolCallFailed("No register_authority_npub tool found on this Authority")
        }

        let (content, isError) = try await client.callTool(
            name: registerTool.name,
            arguments: ["candidate_npub": .string(candidateNpub)]
        )

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            await traffic(.error, label: "Register Authority Npub Error", detail: errorText)
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "Register Authority Npub", detail: String(text.prefix(4000)))
        try await throwIfSoftError(text: text, label: "Register Authority Npub")
        return text
    }

    // MARK: - Confirm Authority Claim (Step 2/3)

    /// Call `confirm_authority_claim` on an Authority's MCP endpoint.
    /// This triggers the MCP to poll Nostr for the candidate's DM reply,
    /// verify it, and escalate to the Prime Authority for approval.
    func callConfirmAuthorityClaim(
        endpointURL: URL,
        candidateNpub: String
    ) async throws -> String {
        await traffic(.outbound, label: "Confirm Claim", detail: "SSE → \(endpointURL.absoluteString) candidate=\(candidateNpub.prefix(16))…")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        guard let tool = allTools.first(where: { $0.name.contains("confirm_authority_claim") }) else {
            await traffic(.error, label: "Confirm Claim", detail: "No confirm_authority_claim tool found")
            throw MCPError.toolCallFailed("No confirm_authority_claim tool found on this Authority")
        }

        let (content, isError) = try await client.callTool(
            name: tool.name,
            arguments: ["candidate_npub": .string(candidateNpub)]
        )

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            await traffic(.error, label: "Confirm Claim Error", detail: errorText)
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "Confirm Claim", detail: String(text.prefix(4000)))
        return text
    }

    // MARK: - Check Authority Approval (Step 3/3)

    /// Call `check_authority_approval` on an Authority's MCP endpoint.
    /// This triggers the MCP to poll Nostr for the Prime Authority's approval,
    /// and on success activates the Authority and registers it in the community.
    func callCheckAuthorityApproval(
        endpointURL: URL,
        candidateNpub: String
    ) async throws -> String {
        await traffic(.outbound, label: "Check Approval", detail: "SSE → \(endpointURL.absoluteString) candidate=\(candidateNpub.prefix(16))…")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        guard let tool = allTools.first(where: { $0.name.contains("check_authority_approval") }) else {
            await traffic(.error, label: "Check Approval", detail: "No check_authority_approval tool found")
            throw MCPError.toolCallFailed("No check_authority_approval tool found on this Authority")
        }

        let (content, isError) = try await client.callTool(
            name: tool.name,
            arguments: ["candidate_npub": .string(candidateNpub)]
        )

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            await traffic(.error, label: "Check Approval Error", detail: errorText)
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "Check Approval", detail: String(text.prefix(4000)))
        return text
    }

    // MARK: - Register Operator (Adopt)

    /// Call `register_operator` on an Authority's MCP endpoint to adopt an operator.
    /// Returns the text response from the tool.
    ///
    /// `authorityNpub` is the Authority's own npub — the wheel (0.26.0+)
    /// requires a second Schnorr proof signed by this npub as cryptographic
    /// witness of the Authority's human consent. The proof is produced
    /// automatically by `argsWithProof` if the Authority's nsec is in
    /// Keychain. Pass an empty string only for the legacy session-priming
    /// use where the Authority is registering its own npub against itself
    /// (operator and Authority are the same identity, so `proof` doubles
    /// as `authority_proof`).
    func callRegisterOperator(
        endpointURL: URL,
        operatorNpub: String,
        operatorServiceURL: String = "",
        displayName: String = "",
        authorityNpub: String = ""
    ) async throws -> String {
        await traffic(.outbound, label: "Register Operator", detail: "SSE → \(endpointURL.absoluteString) npub=\(operatorNpub.prefix(16))…")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        guard let registerTool = allTools.first(where: { $0.name.contains("register_operator") }) else {
            await traffic(.error, label: "Register Operator", detail: "No register_operator tool found")
            throw MCPError.toolCallFailed("No register_operator tool found on this Authority")
        }

        // Tool needs TWO proofs: operator-side + Authority-side consent.
        // Build args explicitly so the shape of the call is visible at the
        // call site, not hidden in a utility's parameter list.
        var extra: [String: Value] = ["service_url": .string(operatorServiceURL)]
        // Carry the operator's chosen name so the community roster is named by it, not a
        // truncated npub (wheel threads display_name through register_operator).
        if !displayName.isEmpty { extra["display_name"] = .string(displayName) }
        var args = await argsWithProof(
            npub: operatorNpub,
            capability: "register_operator",
            endpointURL: endpointURL,
            extra: extra
        )
        if !authorityNpub.isEmpty {
            args["authority_proof"] = .string(await makeIdentityProof(
                forNpub: authorityNpub,
                capability: "register_operator",
                endpointURL: endpointURL
            ))
        }

        let (content, isError) = try await client.callTool(
            name: registerTool.name,
            arguments: args
        )

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            await traffic(.error, label: "Register Operator Error", detail: errorText)
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "Register Operator", detail: String(text.prefix(4000)))
        try await throwIfSoftError(text: text, label: "Register Operator")
        return text
    }

    /// Call `update_operator` on an Authority's MCP endpoint.
    /// See `callRegisterOperator` for `authorityNpub` semantics — required
    /// by wheel 0.26.0+ to witness the Authority's consent to the mutation.
    func callUpdateOperator(
        endpointURL: URL,
        operatorNpub: String,
        serviceURL: String = "",
        displayName: String = "",
        authorityNpub: String = ""
    ) async throws -> String {
        await traffic(.outbound, label: "Update Operator", detail: "SSE → \(endpointURL.absoluteString) npub=\(operatorNpub.prefix(16))…")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        guard let updateTool = allTools.first(where: { $0.name.contains("update_operator") }) else {
            await traffic(.error, label: "Update Operator", detail: "No update_operator tool found")
            throw MCPError.toolCallFailed("No update_operator tool found on this Authority")
        }

        // Tool needs TWO proofs: operator-side + Authority-side consent.
        var args = await argsWithProof(
            npub: operatorNpub,
            capability: "update_operator",
            endpointURL: endpointURL
        )
        if !authorityNpub.isEmpty {
            args["authority_proof"] = .string(await makeIdentityProof(
                forNpub: authorityNpub,
                capability: "update_operator",
                endpointURL: endpointURL
            ))
        }
        if !serviceURL.isEmpty { args["service_url"] = .string(serviceURL) }
        if !displayName.isEmpty { args["display_name"] = .string(displayName) }

        let (content, isError) = try await client.callTool(
            name: updateTool.name,
            arguments: args
        )

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            await traffic(.error, label: "Update Operator Error", detail: errorText)
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "Update Operator", detail: String(text.prefix(4000)))
        try await throwIfSoftError(text: text, label: "Update Operator")
        return text
    }

    /// Call `deregister_operator` on an Authority's MCP endpoint.
    /// See `callRegisterOperator` for `authorityNpub` semantics — required
    /// by wheel 0.26.0+ to witness the Authority's consent to the removal.
    func callDeregisterOperator(
        endpointURL: URL,
        operatorNpub: String,
        authorityNpub: String = ""
    ) async throws -> String {
        await traffic(.outbound, label: "Deregister Operator", detail: "SSE → \(endpointURL.absoluteString) npub=\(operatorNpub.prefix(16))…")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        guard let tool = allTools.first(where: { $0.name.contains("deregister_operator") }) else {
            await traffic(.error, label: "Deregister Operator", detail: "No deregister_operator tool found")
            throw MCPError.toolCallFailed("No deregister_operator tool found on this Authority")
        }

        // Tool needs TWO proofs: operator-side + Authority-side consent.
        var args = await argsWithProof(
            npub: operatorNpub,
            capability: "deregister_operator",
            endpointURL: endpointURL
        )
        if !authorityNpub.isEmpty {
            args["authority_proof"] = .string(await makeIdentityProof(
                forNpub: authorityNpub,
                capability: "deregister_operator",
                endpointURL: endpointURL
            ))
        }

        let (content, isError) = try await client.callTool(
            name: tool.name,
            arguments: args
        )

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            await traffic(.error, label: "Deregister Operator Error", detail: errorText)
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "Deregister Operator", detail: String(text.prefix(4000)))
        try await throwIfSoftError(text: text, label: "Deregister Operator")
        return text
    }

    // MARK: - Deferred Operator Adoption (owner queue)

    /// One pending operator-adoption request, as returned by the Authority's
    /// `list_adoption_requests`. The owner reviews these and decides via
    /// `approve_adoption` / `reject_adoption`. All fields default to empty
    /// when the wheel omits them so a sparse row still decodes.
    struct AdoptionRequest: Decodable, Identifiable, Equatable {
        let operatorNpub: String
        let serviceURL: String
        let note: String
        let requestedAt: String
        let expiresAt: String

        var id: String { operatorNpub }

        enum CodingKeys: String, CodingKey {
            case operatorNpub = "operator_npub"
            case serviceURL = "service_url"
            case note
            case requestedAt = "requested_at"
            case expiresAt = "expires_at"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            operatorNpub = try c.decodeIfPresent(String.self, forKey: .operatorNpub) ?? ""
            serviceURL = try c.decodeIfPresent(String.self, forKey: .serviceURL) ?? ""
            note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
            requestedAt = try c.decodeIfPresent(String.self, forKey: .requestedAt) ?? ""
            expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt) ?? ""
        }

        /// Memberwise init for tests / previews (the Decodable init shadows
        /// the synthesized one).
        init(operatorNpub: String, serviceURL: String = "", note: String = "",
             requestedAt: String = "", expiresAt: String = "") {
            self.operatorNpub = operatorNpub
            self.serviceURL = serviceURL
            self.note = note
            self.requestedAt = requestedAt
            self.expiresAt = expiresAt
        }
    }

    private struct AdoptionListResponse: Decodable {
        let requests: [AdoptionRequest]?
    }

    /// List the Authority's pending operator-adoption requests.
    ///
    /// The single restricted owner-queue tool: gated by an `authority_proof`
    /// signed by the Authority's OWN npub. `makeIdentityProof` produces it
    /// inline from the Keychain nsec, or falls back to a cached poison token;
    /// when neither is held it yields "" and the wheel returns
    /// `authority_consent_required`, which surfaces as `MCPError.structuredError`
    /// for the caller to drive the npub-proof handshake.
    func callListAdoptionRequests(
        endpointURL: URL,
        authorityNpub: String
    ) async throws -> [AdoptionRequest] {
        await traffic(.outbound, label: "List Adoptions", detail: "SSE → \(endpointURL.absoluteString) authority=\(authorityNpub.prefix(16))…")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        guard let tool = allTools.first(where: { $0.name.contains("list_adoption_requests") }) else {
            await traffic(.error, label: "List Adoptions", detail: "No list_adoption_requests tool found")
            throw MCPError.toolCallFailed("No list_adoption_requests tool found on this Authority")
        }

        let args: [String: Value] = [
            "authority_proof": .string(await makeIdentityProof(
                forNpub: authorityNpub,
                capability: "list_adoption_requests",
                endpointURL: endpointURL
            ))
        ]

        let (content, isError) = try await client.callTool(name: tool.name, arguments: args)

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            await traffic(.error, label: "List Adoptions Error", detail: errorText)
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "List Adoptions", detail: String(text.prefix(4000)))
        try await throwIfSoftError(text: text, label: "List Adoptions")

        guard let data = text.data(using: .utf8) else { throw MCPError.invalidResponse }
        let parsed = try JSONDecoder().decode(AdoptionListResponse.self, from: data)
        return parsed.requests ?? []
    }

    /// Approve a pending adoption — provisions the operator (same effect as
    /// `register_operator`). Consent witnessed by the Authority's own proof.
    func callApproveAdoption(
        endpointURL: URL,
        operatorNpub: String,
        authorityNpub: String
    ) async throws -> String {
        await traffic(.outbound, label: "Approve Adoption", detail: "SSE → \(endpointURL.absoluteString) op=\(operatorNpub.prefix(16))…")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        guard let tool = allTools.first(where: { $0.name.contains("approve_adoption") }) else {
            await traffic(.error, label: "Approve Adoption", detail: "No approve_adoption tool found")
            throw MCPError.toolCallFailed("No approve_adoption tool found on this Authority")
        }

        let args: [String: Value] = [
            "operator_npub": .string(operatorNpub),
            "authority_proof": .string(await makeIdentityProof(
                forNpub: authorityNpub,
                capability: "approve_adoption",
                endpointURL: endpointURL
            ))
        ]

        let (content, isError) = try await client.callTool(name: tool.name, arguments: args)

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            await traffic(.error, label: "Approve Adoption Error", detail: errorText)
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "Approve Adoption", detail: String(text.prefix(4000)))
        try await throwIfSoftError(text: text, label: "Approve Adoption")
        return text
    }

    /// Reject a pending adoption (owner consent). `reason` is optional.
    func callRejectAdoption(
        endpointURL: URL,
        operatorNpub: String,
        authorityNpub: String,
        reason: String = ""
    ) async throws -> String {
        await traffic(.outbound, label: "Reject Adoption", detail: "SSE → \(endpointURL.absoluteString) op=\(operatorNpub.prefix(16))…")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        guard let tool = allTools.first(where: { $0.name.contains("reject_adoption") }) else {
            await traffic(.error, label: "Reject Adoption", detail: "No reject_adoption tool found")
            throw MCPError.toolCallFailed("No reject_adoption tool found on this Authority")
        }

        var args: [String: Value] = [
            "operator_npub": .string(operatorNpub),
            "authority_proof": .string(await makeIdentityProof(
                forNpub: authorityNpub,
                capability: "reject_adoption",
                endpointURL: endpointURL
            ))
        ]
        if !reason.isEmpty { args["reason"] = .string(reason) }

        let (content, isError) = try await client.callTool(name: tool.name, arguments: args)

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            await traffic(.error, label: "Reject Adoption Error", detail: errorText)
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "Reject Adoption", detail: String(text.prefix(4000)))
        try await throwIfSoftError(text: text, label: "Reject Adoption")
        return text
    }

    /// Operator-initiated **deferred adoption** — calls `request_adoption` on
    /// the OPERATOR's own MCP endpoint, asking a chosen Authority to adopt it.
    /// The request is delivered MCP-to-MCP to the Authority and recorded as
    /// pending in its Pending Adoptions queue; the operator stays orphaned
    /// until the owner approves. Gated by the operator's OWN npub proof
    /// (`makeIdentityProof` signs it inline from the Keychain nsec, or uses a
    /// cached token); no Authority consent is needed at request time.
    func callRequestAdoption(
        operatorEndpointURL: URL,
        operatorNpub: String,
        authorityNpub: String,
        serviceURL: String = "",
        note: String = ""
    ) async throws -> String {
        await traffic(.outbound, label: "Request Adoption", detail: "SSE → \(operatorEndpointURL.absoluteString) authority=\(authorityNpub.prefix(16))…")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: operatorEndpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        guard let tool = allTools.first(where: { $0.name.contains("request_adoption") }) else {
            await traffic(.error, label: "Request Adoption", detail: "No request_adoption tool found")
            throw MCPError.toolCallFailed("This operator's MCP has no request_adoption tool — it needs tollbooth-dpyc 0.45.0 or newer.")
        }

        var args: [String: Value] = [
            "authority_npub": .string(authorityNpub),
            "dpop_token": .string(await makeIdentityProof(
                forNpub: operatorNpub,
                capability: "request_adoption",
                endpointURL: operatorEndpointURL
            )),
        ]
        if !serviceURL.isEmpty { args["service_url"] = .string(serviceURL) }
        if !note.isEmpty { args["note"] = .string(note) }

        let (content, isError) = try await client.callTool(name: tool.name, arguments: args)

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            await traffic(.error, label: "Request Adoption Error", detail: errorText)
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "Request Adoption", detail: String(text.prefix(4000)))
        try await throwIfSoftError(text: text, label: "Request Adoption")
        return text
    }

    // MARK: - Onboarding Status

    struct OnboardingField: Decodable {
        let field: String
        let category: String
        let status: String
        var how: String?
        var value: String?
        var lifecycle: String?  // "set_once" | "dynamic"
    }

    struct OnboardingStatus: Decodable {
        let ready: Bool
        let configured: [OnboardingField]
        let missing: [OnboardingField]
        var optionalMissing: [OnboardingField] = []
        let summary: String
        var bootstrapError: String?
        var vaultOk: Bool?
        var credentialGreeting: String?
        var credentialService: String?
        var operatorName: String?

        enum CodingKeys: String, CodingKey {
            case ready, configured, missing, summary
            case optionalMissing = "optional_missing"
            case bootstrapError = "bootstrap_error"
            case vaultOk = "vault_ok"
            case credentialGreeting = "credential_greeting"
            case credentialService = "credential_service"
            case operatorName = "operator_name"
        }
    }

    struct PatronOnboardingStatus: Decodable {
        let ready: Bool
        let configured: [OnboardingField]
        let missing: [OnboardingField]
        let summary: String
        var credentialType: String?    // "set_once" | "none_or_dynamic"
        var credentialGreeting: String?
        var credentialService: String?

        enum CodingKeys: String, CodingKey {
            case ready, configured, missing, summary
            case credentialType = "credential_type"
            case credentialGreeting = "credential_greeting"
            case credentialService = "credential_service"
        }
    }

    // MARK: - Persistence Status (network_persistence_health wire model)

    /// The Authority's own certification-ledger reachability. `status` is one
    /// of "ok" | "quota_exceeded" | "error" | "unreachable"; `detail` carries a
    /// human-readable note (e.g. the upstream 402 text) when not "ok".
    struct OwnStoreStatus: Decodable, Sendable {
        let status: String
        let detail: String

        enum CodingKeys: String, CodingKey { case status, detail }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
            detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        }

        init(status: String, detail: String = "") {
            self.status = status
            self.detail = detail
        }
    }

    /// One operator that reported a Neon 402 (quota-exceeded) to this
    /// Authority, coalesced by npub with a first/last-seen window.
    struct OperatorNeonAlert: Decodable, Sendable, Identifiable {
        let operatorNpub: String
        let detail: String
        let seenCount: Int
        let firstSeenAt: String
        let lastSeenAt: String

        var id: String { operatorNpub }

        enum CodingKeys: String, CodingKey {
            case operatorNpub = "operator_npub"
            case detail
            case seenCount = "seen_count"
            case firstSeenAt = "first_seen_at"
            case lastSeenAt = "last_seen_at"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            operatorNpub = try c.decodeIfPresent(String.self, forKey: .operatorNpub) ?? ""
            detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
            seenCount = try c.decodeIfPresent(Int.self, forKey: .seenCount) ?? 0
            firstSeenAt = try c.decodeIfPresent(String.self, forKey: .firstSeenAt) ?? ""
            lastSeenAt = try c.decodeIfPresent(String.self, forKey: .lastSeenAt) ?? ""
        }

        init(operatorNpub: String, detail: String = "", seenCount: Int = 0,
             firstSeenAt: String = "", lastSeenAt: String = "") {
            self.operatorNpub = operatorNpub
            self.detail = detail
            self.seenCount = seenCount
            self.firstSeenAt = firstSeenAt
            self.lastSeenAt = lastSeenAt
        }
    }

    /// One Neon project's compute-hour usage against its monthly allowance.
    /// `status` is "ok" | "warning" | "critical" | "exhausted" | "unknown".
    struct NeonProjectUsage: Decodable, Sendable, Identifiable {
        let projectId: String
        let name: String
        let computeHoursUsed: Double
        let allowanceHours: Double
        let usedPct: Double
        let quotaResetAt: String
        let status: String

        var id: String { projectId }

        enum CodingKeys: String, CodingKey {
            case projectId = "project_id"
            case name
            case computeHoursUsed = "compute_hours_used"
            case allowanceHours = "allowance_hours"
            case usedPct = "used_pct"
            case quotaResetAt = "quota_reset_at"
            case status
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            projectId = try c.decodeIfPresent(String.self, forKey: .projectId) ?? ""
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            computeHoursUsed = try c.decodeIfPresent(Double.self, forKey: .computeHoursUsed) ?? 0
            allowanceHours = try c.decodeIfPresent(Double.self, forKey: .allowanceHours) ?? 0
            usedPct = try c.decodeIfPresent(Double.self, forKey: .usedPct) ?? 0
            quotaResetAt = try c.decodeIfPresent(String.self, forKey: .quotaResetAt) ?? ""
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        }

        init(projectId: String, name: String, computeHoursUsed: Double = 0,
             allowanceHours: Double = 0, usedPct: Double = 0,
             quotaResetAt: String = "", status: String = "unknown") {
            self.projectId = projectId
            self.name = name
            self.computeHoursUsed = computeHoursUsed
            self.allowanceHours = allowanceHours
            self.usedPct = usedPct
            self.quotaResetAt = quotaResetAt
            self.status = status
        }
    }

    /// The Neon control-plane read block. `configured == false` means no Neon
    /// API key is set — proactive monitoring is simply not enabled (calm note,
    /// not an error); `hint` explains how to turn it on. `error` is present
    /// only when a configured poll failed.
    struct NeonApiBlock: Decodable, Sendable {
        let configured: Bool
        let hint: String?
        let error: String?
        let projects: [NeonProjectUsage]

        enum CodingKeys: String, CodingKey {
            case configured, hint, error, projects
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            configured = try c.decodeIfPresent(Bool.self, forKey: .configured) ?? false
            hint = try c.decodeIfPresent(String.self, forKey: .hint)
            error = try c.decodeIfPresent(String.self, forKey: .error)
            projects = try c.decodeIfPresent([NeonProjectUsage].self, forKey: .projects) ?? []
        }

        init(configured: Bool, hint: String? = nil, error: String? = nil,
             projects: [NeonProjectUsage] = []) {
            self.configured = configured
            self.hint = hint
            self.error = error
            self.projects = projects
        }
    }

    /// The `network_persistence_health` response — a restricted Authority read that
    /// surfaces the health of every Neon (Postgres) database this Authority
    /// stewards: its own certification ledgers, the operators that reported a
    /// 402, and the Neon control-plane compute-hour picture.
    struct NeonPersistenceHealth: Decodable, Sendable {
        let success: Bool
        let overallStatus: String   // "ok" | "warning" | "critical" | "exhausted"
        let ownStore: OwnStoreStatus
        let operatorAlerts: [OperatorNeonAlert]
        let operatorAlertCount: Int
        let neonApi: NeonApiBlock

        enum CodingKeys: String, CodingKey {
            case success
            case overallStatus = "overall_status"
            case ownStore = "own_store"
            case operatorAlerts = "operator_alerts"
            case operatorAlertCount = "operator_alert_count"
            case neonApi = "neon_api"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            success = try c.decodeIfPresent(Bool.self, forKey: .success) ?? true
            overallStatus = try c.decodeIfPresent(String.self, forKey: .overallStatus) ?? "unknown"
            ownStore = try c.decodeIfPresent(OwnStoreStatus.self, forKey: .ownStore)
                ?? OwnStoreStatus(status: "unknown")
            operatorAlerts = try c.decodeIfPresent([OperatorNeonAlert].self, forKey: .operatorAlerts) ?? []
            operatorAlertCount = try c.decodeIfPresent(Int.self, forKey: .operatorAlertCount)
                ?? operatorAlerts.count
            neonApi = try c.decodeIfPresent(NeonApiBlock.self, forKey: .neonApi)
                ?? NeonApiBlock(configured: false)
        }

        init(success: Bool = true, overallStatus: String, ownStore: OwnStoreStatus,
             operatorAlerts: [OperatorNeonAlert] = [], operatorAlertCount: Int? = nil,
             neonApi: NeonApiBlock) {
            self.success = success
            self.overallStatus = overallStatus
            self.ownStore = ownStore
            self.operatorAlerts = operatorAlerts
            self.operatorAlertCount = operatorAlertCount ?? operatorAlerts.count
            self.neonApi = neonApi
        }
    }

    /// Call the restricted `network_persistence_health` tool on an Authority's MCP
    /// endpoint. Gated by an `authority_proof` signed by the Authority's OWN
    /// npub — the same owner-consent idiom as `list_adoption_requests`. A
    /// `quota_exhausted` (or any) soft error arrives as
    /// `MCPError.structuredError` via `throwIfSoftError` for the caller to
    /// surface; a healthy response with `overall_status == "exhausted"` is
    /// data, not an error.
    func callNetworkPersistenceHealth(
        endpointURL: URL,
        authorityNpub: String
    ) async throws -> NeonPersistenceHealth {
        await traffic(.outbound, label: "Persistence Health", detail: "SSE → \(endpointURL.absoluteString) authority=\(authorityNpub.prefix(16))…")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        guard let tool = allTools.first(where: { $0.name.contains("network_persistence_health") }) else {
            await traffic(.error, label: "Persistence Health", detail: "No network_persistence_health tool found")
            // Tool-discovery gap, not a health fault: an Authority's wheel that
            // predates network_persistence_health simply doesn't offer the reading.
            // Signalled distinctly so the panel stays calm instead of alarming.
            throw MCPError.capabilityUnavailable(
                capability: "network_persistence_health",
                detail: "This Authority’s wheel doesn’t offer network persistence health monitoring yet."
            )
        }

        // Restricted owner-consent tool: bind the proof to the Authority's own
        // npub under `authority_proof`, exactly like list_adoption_requests.
        let args: [String: Value] = [
            "authority_proof": .string(await makeIdentityProof(
                forNpub: authorityNpub,
                capability: "network_persistence_health",
                endpointURL: endpointURL
            ))
        ]

        let (content, isError) = try await client.callTool(name: tool.name, arguments: args)

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            await traffic(.error, label: "Persistence Health Error", detail: errorText)
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first,
              let data = text.data(using: .utf8) else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "Persistence Health", detail: String(text.prefix(4000)))
        try await throwIfSoftError(text: text, label: "Persistence Health")

        // Unwrap a {"result": {...}} envelope if present, like the other parsers.
        let payloadData: Data
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = obj["result"] as? [String: Any] {
            payloadData = try JSONSerialization.data(withJSONObject: result)
        } else {
            payloadData = data
        }

        return try JSONDecoder().decode(NeonPersistenceHealth.self, from: payloadData)
    }

    func callGetOnboardingStatus(
        endpointURL: URL
    ) async throws -> OnboardingStatus {
        await traffic(.outbound, label: "Onboarding Status", detail: "SSE → \(endpointURL.absoluteString)")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        guard let onboardTool = allTools.first(where: { $0.name.contains("get_operator_onboarding_status") }) else {
            await traffic(.error, label: "Onboarding Status", detail: "No get_operator_onboarding_status tool found")
            throw MCPError.toolCallFailed("No get_operator_onboarding_status tool found")
        }

        let (content, isError) = try await client.callTool(name: onboardTool.name, arguments: [:])

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first,
              let data = text.data(using: .utf8) else {
            throw MCPError.invalidResponse
        }

        let status = try JSONDecoder().decode(OnboardingStatus.self, from: data)
        let logDetail: String
        if let err = status.bootstrapError, !err.isEmpty {
            logDetail = "\(status.summary) | bootstrap: \(err)"
        } else {
            logDetail = status.summary
        }
        await traffic(.inbound, label: "Onboarding Status", detail: logDetail)
        return status
    }

    // MARK: - Patron Onboarding Status

    func callGetPatronOnboardingStatus(
        endpointURL: URL,
        patronNpub: String
    ) async throws -> PatronOnboardingStatus {
        await traffic(.outbound, label: "Patron Onboarding", detail: "SSE → \(endpointURL.absoluteString)")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        guard let tool = allTools.first(where: { $0.name.contains("get_patron_onboarding_status") }) else {
            await traffic(.inbound, label: "Patron Onboarding", detail: "Tool not found — operator may not require patron credentials")
            // Return a synthetic "no patron credentials needed" status
            return PatronOnboardingStatus(
                ready: true,
                configured: [],
                missing: [],
                summary: "Operator does not report patron credential requirements.",
                credentialType: "none_or_dynamic"
            )
        }

        let (content, isError) = try await client.callTool(
            name: tool.name,
            arguments: await argsWithProof(
                npub: patronNpub,
                capability: "get_patron_onboarding_status",
                endpointURL: endpointURL,
                npubKey: "patron_npub"
            )
        )

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first,
              let data = text.data(using: .utf8) else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "Patron Onboarding", detail: String(text.prefix(4000)))
        return try JSONDecoder().decode(PatronOnboardingStatus.self, from: data)
    }

    // MARK: - Secure Courier

    func callRequestCredentialChannel(
        endpointURL: URL,
        senderNpub: String,
        service: String
    ) async throws -> String {
        await traffic(.outbound, label: "Credential Channel", detail: "SSE → \(endpointURL.absoluteString) npub=\(senderNpub.prefix(16))…")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        guard let tool = allTools.first(where: { $0.name.contains("request_credential_channel") }) else {
            await traffic(.error, label: "Credential Channel", detail: "No request_credential_channel tool found")
            throw MCPError.toolCallFailed("Operator does not support Secure Courier")
        }

        let (content, isError) = try await client.callTool(
            name: tool.name,
            arguments: [
                "sender_npub": .string(senderNpub),
                "service": .string(service),
            ]
        )

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first else {
            return "Secure Courier channel opened. Check your Nostr DMs for the credential template."
        }

        await traffic(.inbound, label: "Credential Channel", detail: String(text.prefix(4000)))
        try await throwIfSoftError(text: text, label: "Credential Channel")
        return text
    }

    func callReceiveCredentials(
        endpointURL: URL,
        senderNpub: String,
        service: String = "",
        poison: String = "",
        credentialCard: String = ""
    ) async throws -> String {
        let label = credentialCard.isEmpty ? "Receive Credentials" : "Redeem ncred"
        await traffic(.outbound, label: label, detail: "SSE → \(endpointURL.absoluteString) npub=\(senderNpub.prefix(16))…")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        guard let tool = allTools.first(where: { $0.name.contains("receive_credentials") }) else {
            await traffic(.error, label: "Receive Credentials", detail: "No receive_credentials tool found")
            throw MCPError.toolCallFailed("Operator does not support receive_credentials")
        }

        var args: [String: Value] = [
            "sender_npub": .string(senderNpub),
        ]
        if !service.isEmpty {
            args["service"] = .string(service)
        }
        // The session phrase from request_credential_channel — sent as the wheel's
        // `dpop_token` (renamed from "poison" in SDK 0.57.0; the wheel's pydantic
        // arg validation rejects the old `poison` keyword). Required by the wheel
        // unless redeeming a credential card.
        if !poison.isEmpty {
            args["dpop_token"] = .string(poison)
        }
        if !credentialCard.isEmpty {
            args["credential_card"] = .string(credentialCard)
        }
        let (content, isError) = try await client.callTool(
            name: tool.name,
            arguments: args
        )

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "Receive Credentials", detail: String(text.prefix(4000)))
        return text
    }

    func callForgetCredentials(
        endpointURL: URL,
        service: String,
        npub: String
    ) async throws {
        await traffic(.outbound, label: "Forget Credentials", detail: "service=\(service) npub=\(npub.prefix(16))…")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        guard let tool = allTools.first(where: { $0.name.contains("forget_credentials") }) else {
            await traffic(.error, label: "Forget Credentials", detail: "No forget_credentials tool found")
            throw MCPError.toolCallFailed("Operator does not support forget_credentials")
        }

        let (content, isError) = try await client.callTool(
            name: tool.name,
            arguments: await argsWithProof(npub: npub, capability: "forget_credentials", endpointURL: endpointURL, extra: ["service": .string(service)])
        )

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            throw MCPError.toolCallFailed(errorText)
        }

        let text = content.compactMap { extractText($0) }.first ?? ""
        await traffic(.inbound, label: "Forget Credentials", detail: String(text.prefix(4000)))
        if !text.isEmpty {
            try await throwIfSoftError(text: text, label: "Forget Credentials")
        }
    }

    // MARK: - Pricing Synthesis

    /// Connects to an operator's MCP, lists all tools, and synthesizes a pricing model
    /// by inferring category and price from tool names.
    private func synthesizePricingModel(endpointURL: URL) async throws -> PricingModelResponse {
        await traffic(.outbound, label: "Operator Connect", detail: "SSE → \(endpointURL.absoluteString) (Bearer auth)")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
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
                toolId: ToolPrice.capabilityUUID(tool.name),
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
            trancheLifetime: nil
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
            || name.contains("check_balance") || name.contains("list_notarizations") {
            return ("free", 0)
        }

        // Restricted — operator-only tools
        if name.contains("set_pricing_model") {
            return ("restricted", 0)
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

    // MARK: - Canonical Identity Introspection

    /// Canonical (tool_id, mcp_name, …) tuple as the wheel itself
    /// reports them. Source of truth for any client that needs to
    /// UUID-join against the stored pricing model.
    ///
    /// Requires tollbooth-dpyc 0.38.0 or newer on the operator side —
    /// the `list_canonical_identities` tool was added in that release.
    struct CanonicalIdentity: Sendable {
        let toolId: String
        let mcpName: String
        let category: String
        let intent: String
    }

    /// Call the wheel's `list_canonical_identities` tool and decode
    /// the returned canonical inventory. Throws if the operator is on
    /// an older wheel that doesn't expose the tool.
    func fetchCanonicalIdentities(endpointURL: URL) async throws -> [CanonicalIdentity] {
        await traffic(.outbound, label: "Canonical Identities",
                       detail: "SSE → \(endpointURL.absoluteString)")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }
        try await client.connect(transport: transport)

        // tools/list to find the wheel's `list_canonical_identities` —
        // its mcp_name is `<slug>_list_canonical_identities`.
        let allTools = try await listAllTools(client: client)
        guard let canon = allTools.first(where: { $0.name.hasSuffix("_list_canonical_identities") })
        else {
            throw MCPError.toolCallFailed(
                "This operator does not expose list_canonical_identities. " +
                "Upgrade the operator to tollbooth-dpyc 0.38.0+ and redeploy."
            )
        }

        let (content, isError) = try await client.callTool(name: canon.name, arguments: [:])
        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            throw MCPError.toolCallFailed(errorText)
        }
        let text = content.compactMap { extractText($0) }.first ?? ""
        guard let data = text.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tools = payload["tools"] as? [[String: Any]]
        else {
            throw MCPError.toolCallFailed(
                "list_canonical_identities returned unexpected payload: \(text.prefix(200))"
            )
        }

        var out: [CanonicalIdentity] = []
        for entry in tools {
            guard let id = entry["tool_id"] as? String,
                  let name = entry["mcp_name"] as? String
            else { continue }
            let category = entry["category"] as? String ?? "read"
            let intent = entry["intent"] as? String ?? ""
            out.append(CanonicalIdentity(
                toolId: id, mcpName: name, category: category, intent: intent,
            ))
        }
        await traffic(.inbound, label: "Canonical Identities",
                       detail: "Returned \(out.count) tool identities")
        return out
    }

    // MARK: - Tool Mismatch Detection

    /// Mismatch between the wheel's canonical inventory and the stored
    /// pricing model. UUID-joined — no name-based heuristics, no local
    /// UUID derivation. The wheel is the source of truth.
    struct ToolMismatch: Sendable {
        /// Canonical tools the wheel reports that aren't in the stored model yet.
        let newIdentities: [CanonicalIdentity]
        /// Stored rows whose toolId isn't in the wheel's canonical set — tool was removed in code.
        let staleTools: [ToolPrice]
        /// Stored rows that matched a canonical entry by UUID. Each pair carries the live
        /// canonical so the FE can surface drift in name/category/intent.
        let matchedPairs: [(stored: ToolPrice, canonical: CanonicalIdentity)]
        var matchedTools: [ToolPrice] { matchedPairs.map(\.stored) }
        var hasMismatch: Bool { !newIdentities.isEmpty || !staleTools.isEmpty }
    }

    /// Connect to the live MCP, fetch its canonical identities, and
    /// UUID-join against the stored pricing model.
    func detectToolMismatch(
        endpointURL: URL,
        storedModel: PricingModelResponse,
        operatorSlug: String? = nil
    ) async throws -> ToolMismatch {
        // operatorSlug is no longer used for matching — the canonical
        // identities already carry the slug-prefixed mcp_name as the
        // wheel computes it. Kept in the signature for API compat with
        // any caller that still passes it.
        _ = operatorSlug

        let canonical = try await fetchCanonicalIdentities(endpointURL: endpointURL)
        let storedTools = storedModel.tools ?? []

        let canonicalById = Dictionary(uniqueKeysWithValues: canonical.map { ($0.toolId, $0) })
        let storedById = Dictionary(uniqueKeysWithValues: storedTools.map { ($0.toolId, $0) })

        var newIdentities: [CanonicalIdentity] = []
        var matchedPairs: [(stored: ToolPrice, canonical: CanonicalIdentity)] = []
        for c in canonical {
            if let stored = storedById[c.toolId] {
                matchedPairs.append((stored: stored, canonical: c))
            } else {
                newIdentities.append(c)
            }
        }
        let staleTools = storedTools.filter { canonicalById[$0.toolId] == nil }

        await traffic(.inbound, label: "Mismatch Detection",
                       detail: "Canonical: \(canonical.count), Stored: \(storedTools.count), " +
                               "New: \(newIdentities.count), Stale: \(staleTools.count), " +
                               "Matched: \(matchedPairs.count)")

        return ToolMismatch(
            newIdentities: newIdentities,
            staleTools: staleTools,
            matchedPairs: matchedPairs
        )
    }

    // MARK: - Generic Tool Call

    /// Call any MCP tool by name and return the text response.
    /// Handles SSE connect/call/disconnect lifecycle.
    func callToolGeneric(
        endpointURL: URL,
        toolName: String,
        arguments: [String: Value] = [:]
    ) async throws -> String {
        await traffic(.outbound, label: "Test Call", detail: "\(toolName) → \(endpointURL.absoluteString)")
        let text = try await _connectAndCall(
            endpointURL: endpointURL,
            toolName: toolName,
            arguments: arguments
        )
        await traffic(.inbound, label: "Test Call Result", detail: String(text.prefix(4000)))
        return text
    }

    /// Shared lifecycle: connect → list → resolve short-name → call →
    /// return joined text. Used by all single-tool MCP calls so the
    /// retrieval path is unified — no caller has its own connect or
    /// resolve logic.
    private func _connectAndCall(
        endpointURL: URL,
        toolName: String,
        arguments: [String: Value]
    ) async throws -> String {
        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        let resolvedName: String
        if let match = allTools.first(where: { $0.name == toolName }) {
            resolvedName = match.name
        } else if let match = allTools.first(where: { $0.name.hasSuffix("_\(toolName)") }) {
            resolvedName = match.name
        } else {
            // Surface as a typed error so callers can distinguish
            // "tool absent on operator" from "tool returned an error".
            throw MCPError.toolCallFailed("Tool '\(toolName)' not found on operator endpoint")
        }

        let (content, isError) = try await client.callTool(name: resolvedName, arguments: arguments)

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            throw MCPError.toolCallFailed(errorText)
        }

        return content.compactMap { extractText($0) }.joined(separator: "\n")
    }

    /// Fetch the tool list from an operator endpoint (connect, list, disconnect).
    func fetchToolList(
        endpointURL: URL
    ) async throws -> [Tool] {
        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)
        return try await listAllTools(client: client)
    }

    // MARK: - Helpers

    /// List all tools with cursor-based pagination.
    func listAllTools(client: Client) async throws -> [Tool] {
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
    func extractText(_ content: Tool.Content) -> String? {
        switch content {
        case .text(let text, _, _):
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
    /// The endpoint's wheel simply doesn't expose a capability (the tool is
    /// absent from `tools/list`) — a *discovery* gap, distinct from a tool
    /// that ran and failed. Callers rendering health surfaces must present
    /// this as "not offered here yet", NOT as a backend/datastore fault.
    case capabilityUnavailable(capability: String, detail: String)
    /// Wheel returned a structured soft error: `{"success": false, "error_code": "...", "error": "..."}`.
    /// `extras` carries any additional context fields the wheel volunteered
    /// (e.g. `authority_npub` on `authority_consent_required`). Views can
    /// branch on `code` to render a remedy flow.
    case structuredError(code: String, message: String, extras: [String: String])

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from MCP server"
        case .noPricingTool: return "No pricing model tool found on this operator"
        case .connectionFailed(let msg): return "MCP connection failed: \(msg)"
        case .toolCallFailed(let msg): return "MCP tool call failed: \(msg)"
        case .capabilityUnavailable(_, let detail): return detail
        case .structuredError(_, let msg, _): return msg
        }
    }

    /// Convenience accessor for branching on the wheel's error_code without unwrapping.
    var errorCode: String? {
        if case .structuredError(let code, _, _) = self { return code }
        return nil
    }

    /// Convenience accessor for extras carried alongside a structured error.
    var errorExtras: [String: String] {
        if case .structuredError(_, _, let extras) = self { return extras }
        return [:]
    }
}

// MARK: - Campaign Publishing (via Oracle)

extension MCPService {

    /// Publish a campaign to dpyc-community via the Oracle's publish_campaign tool.
    func callPublishCampaign(
        oracleURL: URL,
        authorNpub: String,
        operatorNpub: String,
        campaignJSON: String,
        campaignName: String,
        campaignMarkdown: String = ""
    ) async throws -> String {
        await traffic(.outbound, label: "Publish Campaign", detail: "SSE → \(oracleURL.absoluteString)")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: oracleURL)
        defer { Task { await client.disconnect() } }

        try await client.connect(transport: transport)

        let allTools = try await listAllTools(client: client)
        guard let publishTool = allTools.first(where: { $0.name.contains("publish_campaign") }) else {
            await traffic(.error, label: "Publish Campaign", detail: "No publish_campaign tool found")
            throw MCPError.toolCallFailed("No publish_campaign tool found on Oracle")
        }

        let (content, isError) = try await client.callTool(
            name: publishTool.name,
            arguments: [
                "author_npub": .string(authorNpub),
                "operator_npub": .string(operatorNpub),
                "campaign_json": .string(campaignJSON),
                "campaign_name": .string(campaignName),
                "campaign_markdown": .string(campaignMarkdown),
            ]
        )

        let text = content.compactMap { extractText($0) }.joined()

        if isError == true {
            await traffic(.error, label: "Publish Campaign Error", detail: text)
            throw MCPError.toolCallFailed(text)
        }

        await traffic(.inbound, label: "Publish Campaign", detail: String(text.prefix(4000)))
        try await throwIfSoftError(text: text, label: "Publish Campaign")
        return text
    }

    // MARK: - Coupon CRUD (wheel 0.41.0+)

    /// Mint a new operator-owned discount coupon.
    func callMintCoupon(
        endpointURL: URL,
        operatorNpub: String,
        name: String,
        discountPercent: Double,
        validFrom: Date,
        validUntil: Date,
        usesPerPatron: Int?,
        totalUses: Int?
    ) async throws -> Coupon {
        await traffic(.outbound, label: "Mint Coupon", detail: "\(name) — \(discountPercent)% off")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }
        try await client.connect(transport: transport)

        let tool = try await findCouponTool(client: client, suffix: "mint_coupon")
        let proof = try await signRuntimeProof(
            capability: "mint_coupon",
            endpointURL: endpointURL,
            operatorNpub: operatorNpub,
        )

        var args: [String: Value] = [
            "name": .string(name),
            "discount_percent": .double(discountPercent),
            "valid_from": .string(isoFormatter.string(from: validFrom)),
            "valid_until": .string(isoFormatter.string(from: validUntil)),
            "dpop_token": .string(proof),
        ]
        if let upp = usesPerPatron { args["uses_per_patron"] = .int(upp) }
        if let tu = totalUses { args["total_uses"] = .int(tu) }

        let json = try await callJSONTool(client: client, name: tool.name, arguments: args, label: "Mint Coupon")
        return try decodeCoupon(from: json, key: "coupon", label: "Mint Coupon")
    }

    /// List the operator's coupons (newest first per server order).
    func callListCoupons(
        endpointURL: URL,
        operatorNpub: String
    ) async throws -> [Coupon] {
        await traffic(.outbound, label: "List Coupons", detail: "SSE → \(endpointURL.absoluteString)")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }
        try await client.connect(transport: transport)

        let tool = try await findCouponTool(client: client, suffix: "list_coupons")
        let proof = try await signRuntimeProof(
            capability: "list_coupons",
            endpointURL: endpointURL,
            operatorNpub: operatorNpub,
        )

        let json = try await callJSONTool(
            client: client, name: tool.name,
            arguments: ["dpop_token": .string(proof)],
            label: "List Coupons",
        )

        guard let rows = json["coupons"] as? [[String: Any]] else { return [] }
        let data = try JSONSerialization.data(withJSONObject: rows)
        let decoder = JSONDecoder()
        return try decoder.decode([Coupon].self, from: data)
    }

    /// Patch a coupon's editable fields.  Pass only the fields you
    /// want to change.  Use ``clearUsesPerPatron`` / ``clearTotalUses``
    /// to set the cap to NULL (unlimited).
    func callUpdateCoupon(
        endpointURL: URL,
        operatorNpub: String,
        couponId: String,
        name: String? = nil,
        discountPercent: Double? = nil,
        validFrom: Date? = nil,
        validUntil: Date? = nil,
        usesPerPatron: Int? = nil,
        totalUses: Int? = nil,
        clearUsesPerPatron: Bool = false,
        clearTotalUses: Bool = false
    ) async throws -> Coupon {
        await traffic(.outbound, label: "Update Coupon", detail: couponId.prefix(8) + "…")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }
        try await client.connect(transport: transport)

        let tool = try await findCouponTool(client: client, suffix: "update_coupon")
        let proof = try await signRuntimeProof(
            capability: "update_coupon",
            endpointURL: endpointURL,
            operatorNpub: operatorNpub,
        )

        var args: [String: Value] = [
            "coupon_id": .string(couponId),
            "dpop_token": .string(proof),
        ]
        if let n = name { args["name"] = .string(n) }
        if let d = discountPercent { args["discount_percent"] = .double(d) }
        if let vf = validFrom { args["valid_from"] = .string(isoFormatter.string(from: vf)) }
        if let vu = validUntil { args["valid_until"] = .string(isoFormatter.string(from: vu)) }
        if let upp = usesPerPatron { args["uses_per_patron"] = .int(upp) }
        if let tu = totalUses { args["total_uses"] = .int(tu) }
        if clearUsesPerPatron { args["clear_uses_per_patron"] = .bool(true) }
        if clearTotalUses { args["clear_total_uses"] = .bool(true) }

        let json = try await callJSONTool(client: client, name: tool.name, arguments: args, label: "Update Coupon")
        return try decodeCoupon(from: json, key: "coupon", label: "Update Coupon")
    }

    /// Delete a coupon (cascades to all patron redemptions).
    func callDeleteCoupon(
        endpointURL: URL,
        operatorNpub: String,
        couponId: String
    ) async throws {
        await traffic(.outbound, label: "Delete Coupon", detail: couponId.prefix(8) + "…")

        let client = Client(name: "PricingStudio", version: "1.0.0")
        let transport = makeTransport(endpoint: endpointURL)
        defer { Task { await client.disconnect() } }
        try await client.connect(transport: transport)

        let tool = try await findCouponTool(client: client, suffix: "delete_coupon")
        let proof = try await signRuntimeProof(
            capability: "delete_coupon",
            endpointURL: endpointURL,
            operatorNpub: operatorNpub,
        )

        _ = try await callJSONTool(
            client: client, name: tool.name,
            arguments: [
                "coupon_id": .string(couponId),
                "dpop_token": .string(proof),
            ],
            label: "Delete Coupon",
        )
    }

    // MARK: - Coupon helpers

    private var isoFormatter: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    private func findCouponTool(
        client: Client, suffix: String,
    ) async throws -> Tool {
        let all = try await listAllTools(client: client)
        guard let t = all.first(where: { $0.name.hasSuffix("_" + suffix) || $0.name == suffix }) else {
            await traffic(.error, label: "Coupon Tool", detail: "No \(suffix) tool found")
            throw MCPError.toolCallFailed("No \(suffix) tool found on this MCP")
        }
        return t
    }

    private func callJSONTool(
        client: Client,
        name: String,
        arguments: [String: Value],
        label: String,
    ) async throws -> [String: Any] {
        await traffic(.outbound, label: "callTool: \(name)", detail: "args=\(arguments.keys.sorted().joined(separator: ","))")
        let (content, isError) = try await client.callTool(name: name, arguments: arguments)
        let text = content.compactMap { extractText($0) }.joined()
        if isError == true {
            await traffic(.error, label: "\(label) Error", detail: text)
            throw MCPError.toolCallFailed(text)
        }
        await traffic(.inbound, label: label, detail: String(text.prefix(4000)))
        try await throwIfSoftError(text: text, label: label)
        guard
            let data = text.data(using: .utf8),
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw MCPError.invalidResponse
        }
        if let success = json["success"] as? Bool, success == false {
            let err = (json["error"] as? String) ?? "Unknown error"
            throw MCPError.toolCallFailed(err)
        }
        return json
    }

    private func decodeCoupon(
        from json: [String: Any], key: String, label: String,
    ) throws -> Coupon {
        guard let row = json[key] as? [String: Any] else {
            throw MCPError.toolCallFailed("\(label) response missing '\(key)'")
        }
        let data = try JSONSerialization.data(withJSONObject: row)
        return try JSONDecoder().decode(Coupon.self, from: data)
    }
}
