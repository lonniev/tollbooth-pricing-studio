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

        // Try stored pricing first
        if let stored = try? await callGetPricingModel(endpointURL: endpointURL, bearerToken: bearerToken),
           stored.tools != nil {
            var result = stored
            result.source = .stored
            onStep(.done)
            return result
        }

        // Fall back to synthesized pricing
        var result = try await synthesizePricingModel(endpointURL: endpointURL, bearerToken: bearerToken)
        result.source = .synthesized

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

        let balance = (balanceDict["balance_api_sats"] as? Int) ?? 0
        let deposited = (balanceDict["total_deposited_api_sats"] as? Int) ?? 0
        let consumed = (balanceDict["total_consumed_api_sats"] as? Int) ?? 0
        let expired = (balanceDict["total_expired_api_sats"] as? Int) ?? 0
        let tranches = (balanceDict["active_tranches"] as? Int) ?? 0
        let expiring24h = (balanceDict["expiring_within_24h_sats"] as? Int) ?? 0

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFallback = ISO8601DateFormatter()
        isoFallback.formatOptions = [.withInternetDateTime]

        func parseISO(_ str: String) -> Date? {
            isoFormatter.date(from: str) ?? isoFallback.date(from: str)
        }

        var nextExpiration: Date? = nil
        if let isoStr = balanceDict["next_expiration_iso"] as? String {
            nextExpiration = parseISO(isoStr)
        }

        var trancheDetails: [PatronAccountViewModel.TrancheDetail] = []
        if let trancheArray = balanceDict["tranches"] as? [[String: Any]] {
            for (index, t) in trancheArray.enumerated() {
                let amount = (t["amount_sats"] as? Int) ?? 0
                let remaining = (t["remaining_sats"] as? Int) ?? amount
                let expiresAt = (t["expires_at"] as? String).flatMap { parseISO($0) }
                let createdAt = (t["created_at"] as? String).flatMap { parseISO($0) }
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
        bearerToken: String
    ) async throws -> InfographicResult {
        await traffic(.outbound, label: "Statement Infographic", detail: "SSE → \(endpointURL.absoluteString)")

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
        guard let infoTool = allTools.first(where: { $0.name.contains("account_statement_infographic") }) else {
            await traffic(.inbound, label: "Statement Infographic", detail: "Tool not found on this operator")
            throw MCPError.toolCallFailed("No account_statement_infographic tool found")
        }

        let (content, isError) = try await client.callTool(name: infoTool.name, arguments: [:])

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            await traffic(.error, label: "Statement Infographic Error", detail: errorText)
            throw MCPError.toolCallFailed(errorText)
        }

        // Check for image content first (PNG/JPEG)
        for item in content {
            if case .image(let data, let mimeType, _) = item {
                await traffic(.inbound, label: "Statement Infographic", detail: "Image received: \(mimeType)")
                return InfographicResult(svgContent: nil, pngBase64: data, generatedAt: nil)
            }
        }

        // Fall back to text content (SVG or JSON wrapper)
        guard let text = content.compactMap({ extractText($0) }).first else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "Statement Infographic", detail: "Text response (\(text.count) chars)")

        // If it's raw SVG
        if text.contains("<svg") {
            return InfographicResult(svgContent: text, pngBase64: nil, generatedAt: nil)
        }

        // Try JSON with svg/png fields
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
        bearerToken: String,
        amountSats: Int
    ) async throws -> PurchaseResult {
        await traffic(.outbound, label: "Purchase Credits", detail: "SSE → \(endpointURL.absoluteString) amount=\(amountSats)")

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
        guard let purchaseTool = allTools.first(where: { $0.name.contains("purchase_credits") }) else {
            await traffic(.error, label: "Purchase Credits", detail: "No purchase_credits tool found")
            throw MCPError.toolCallFailed("No purchase_credits tool found")
        }

        let (content, isError) = try await client.callTool(
            name: purchaseTool.name,
            arguments: ["amount_sats": .int(amountSats)]
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

        await traffic(.inbound, label: "Purchase Credits", detail: String(text.prefix(500)))

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

    func callCheckPayment(
        endpointURL: URL,
        bearerToken: String,
        invoiceId: String
    ) async throws -> CheckPaymentResult {
        await traffic(.outbound, label: "Check Payment", detail: "SSE → \(endpointURL.absoluteString) invoice=\(invoiceId)")

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
        guard let paymentTool = allTools.first(where: { $0.name.contains("check_payment") }) else {
            await traffic(.error, label: "Check Payment", detail: "No check_payment tool found")
            throw MCPError.toolCallFailed("No check_payment tool found")
        }

        let (content, isError) = try await client.callTool(
            name: paymentTool.name,
            arguments: ["invoice_id": .string(invoiceId)]
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

        await traffic(.inbound, label: "Check Payment", detail: String(text.prefix(500)))

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
    func callGetPricingModel(
        endpointURL: URL,
        bearerToken: String
    ) async throws -> PricingModelResponse? {
        await traffic(.outbound, label: "Get Pricing Model", detail: "SSE → \(endpointURL.absoluteString)")

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
        guard let pricingTool = allTools.first(where: { $0.name.contains("get_pricing_model") }) else {
            await traffic(.inbound, label: "Get Pricing Model", detail: "Tool not found — operator doesn't support stored pricing")
            return nil
        }

        let (content, isError) = try await client.callTool(name: pricingTool.name, arguments: [:])

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            await traffic(.error, label: "Get Pricing Model Error", detail: errorText)
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first,
              let data = text.data(using: .utf8) else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "Get Pricing Model", detail: String(text.prefix(500)))

        let response = try JSONDecoder().decode(PricingModelResponse.self, from: data)

        // If tools is nil, no active model stored
        guard response.tools != nil else { return nil }

        return response
    }

    // MARK: - Set Pricing Model

    /// Payload for serializing a pricing model to the format expected by set_pricing_model.
    private struct SetPricingPayload: Encodable {
        let modelId: String?
        let name: String
        let tools: [ToolPrice]
        let pipeline: [PipelineStep]?

        enum CodingKeys: String, CodingKey {
            case modelId = "model_id"
            case name, tools, pipeline
        }
    }

    /// Call set_pricing_model on an operator's MCP endpoint.
    /// Returns the model_id of the created/updated model.
    ///
    /// - Parameters:
    ///   - endpointURL: The operator's MCP SSE endpoint.
    ///   - bearerToken: OAuth bearer token for the session.
    ///   - model: The pricing model to save.
    ///   - operatorNpub: If provided, generates a kind-27235 operator proof
    ///     so a patron session can prove operator authority.
    func callSetPricingModel(
        endpointURL: URL,
        bearerToken: String,
        model: PricingModelResponse,
        operatorNpub: String? = nil
    ) async throws -> String {
        await traffic(.outbound, label: "Set Pricing Model", detail: "SSE → \(endpointURL.absoluteString)")

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
        guard let setTool = allTools.first(where: { $0.name.contains("set_pricing_model") }) else {
            await traffic(.error, label: "Set Pricing Model", detail: "No set_pricing_model tool found")
            throw MCPError.toolCallFailed("No set_pricing_model tool found")
        }

        // Build the model_json payload
        let effectiveModelId = (model.modelId != "synthesized") ? model.modelId : nil
        let payload = SetPricingPayload(
            modelId: effectiveModelId,
            name: model.name ?? "Pricing Model",
            tools: model.tools ?? [],
            pipeline: model.pipeline
        )
        var jsonData = try JSONEncoder().encode(payload)

        // Include operator_proof INSIDE the model_json payload (not as a separate argument)
        if let npub = operatorNpub {
            let proof = try OperatorProofService.createProof(
                toolName: "set_pricing_model",
                operatorNpub: npub
            )
            // Decode, inject proof, re-encode
            if var dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                dict["operator_proof"] = proof
                jsonData = (try? JSONSerialization.data(withJSONObject: dict)) ?? jsonData
            }
            await traffic(.outbound, label: "Operator Proof", detail: "Signed kind-27235 for \(npub.prefix(16))…")
        }

        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
        let arguments: [String: Value] = ["model_json": .string(jsonString)]

        await traffic(.outbound, label: "callTool: \(setTool.name)", detail: "model_json: \(String(jsonString.prefix(500)))")

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

        await traffic(.inbound, label: "Set Pricing Model", detail: String(text.prefix(500)))

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
        endpointURL: URL,
        bearerToken: String
    ) async throws -> [String: String]? {
        await traffic(.outbound, label: "Service Status", detail: "SSE → \(endpointURL.absoluteString)")

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

        await traffic(.inbound, label: "Service Status", detail: String(text.prefix(500)))

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.invalidResponse
        }

        // Extract versions dict — keys and values are both strings
        guard let versions = json["versions"] as? [String: String] else {
            return nil
        }

        return versions
    }

    // MARK: - Register Authority Npub (Claim)

    /// Call `register_authority_npub` on an Authority's MCP endpoint to initiate
    /// the adoption protocol. Returns the text response from the tool.
    func callRegisterAuthorityNpub(
        endpointURL: URL,
        bearerToken: String,
        candidateNpub: String
    ) async throws -> String {
        await traffic(.outbound, label: "Register Authority Npub", detail: "SSE → \(endpointURL.absoluteString) candidate=\(candidateNpub)")

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

        await traffic(.inbound, label: "Register Authority Npub", detail: String(text.prefix(500)))
        return text
    }

    // MARK: - Confirm Authority Claim (Step 2/3)

    /// Call `confirm_authority_claim` on an Authority's MCP endpoint.
    /// This triggers the MCP to poll Nostr for the candidate's DM reply,
    /// verify it, and escalate to the Prime Authority for approval.
    func callConfirmAuthorityClaim(
        endpointURL: URL,
        bearerToken: String,
        candidateNpub: String
    ) async throws -> String {
        await traffic(.outbound, label: "Confirm Claim", detail: "SSE → \(endpointURL.absoluteString) candidate=\(candidateNpub.prefix(16))…")

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

        await traffic(.inbound, label: "Confirm Claim", detail: String(text.prefix(500)))
        return text
    }

    // MARK: - Check Authority Approval (Step 3/3)

    /// Call `check_authority_approval` on an Authority's MCP endpoint.
    /// This triggers the MCP to poll Nostr for the Prime Authority's approval,
    /// and on success activates the Authority and registers it in the community.
    func callCheckAuthorityApproval(
        endpointURL: URL,
        bearerToken: String,
        candidateNpub: String
    ) async throws -> String {
        await traffic(.outbound, label: "Check Approval", detail: "SSE → \(endpointURL.absoluteString) candidate=\(candidateNpub.prefix(16))…")

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

        await traffic(.inbound, label: "Check Approval", detail: String(text.prefix(500)))
        return text
    }

    // MARK: - Register Operator (Adopt)

    /// Call `register_operator` on an Authority's MCP endpoint to adopt an operator.
    /// Returns the text response from the tool.
    func callRegisterOperator(
        endpointURL: URL,
        bearerToken: String,
        operatorNpub: String
    ) async throws -> String {
        await traffic(.outbound, label: "Register Operator", detail: "SSE → \(endpointURL.absoluteString) npub=\(operatorNpub.prefix(16))…")

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
        guard let registerTool = allTools.first(where: { $0.name.contains("register_operator") }) else {
            await traffic(.error, label: "Register Operator", detail: "No register_operator tool found")
            throw MCPError.toolCallFailed("No register_operator tool found on this Authority")
        }

        let (content, isError) = try await client.callTool(
            name: registerTool.name,
            arguments: ["npub": .string(operatorNpub)]
        )

        if isError == true {
            let errorText = content.compactMap { extractText($0) }.joined(separator: "\n")
            await traffic(.error, label: "Register Operator Error", detail: errorText)
            throw MCPError.toolCallFailed(errorText)
        }

        guard let text = content.compactMap({ extractText($0) }).first else {
            throw MCPError.invalidResponse
        }

        await traffic(.inbound, label: "Register Operator", detail: String(text.prefix(500)))
        return text
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

    // MARK: - Tool Mismatch Detection

    struct ToolMismatch: Sendable {
        let newTools: [Tool]          // in live endpoint, not in stored model
        let staleTools: [ToolPrice]   // in stored model, not in live endpoint
        let matchedTools: [ToolPrice] // in both
        var hasMismatch: Bool { !newTools.isEmpty || !staleTools.isEmpty }
    }

    /// Connect to the live MCP endpoint, list tools, and compare against the stored pricing model.
    func detectToolMismatch(
        endpointURL: URL,
        bearerToken: String,
        storedModel: PricingModelResponse
    ) async throws -> ToolMismatch {
        await traffic(.outbound, label: "Mismatch Detection", detail: "SSE → \(endpointURL.absoluteString)")

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

        let liveTools = try await listAllTools(client: client)
        let liveNames = Set(liveTools.map(\.name))
        let storedTools = storedModel.tools ?? []
        let storedNames = Set(storedTools.map(\.toolName))

        let newTools = liveTools.filter { !storedNames.contains($0.name) }
        let staleTools = storedTools.filter { !liveNames.contains($0.toolName) }
        let matchedTools = storedTools.filter { liveNames.contains($0.toolName) }

        await traffic(.inbound, label: "Mismatch Detection",
                       detail: "Live: \(liveTools.count), Stored: \(storedTools.count), New: \(newTools.count), Stale: \(staleTools.count)")

        return ToolMismatch(newTools: newTools, staleTools: staleTools, matchedTools: matchedTools)
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
