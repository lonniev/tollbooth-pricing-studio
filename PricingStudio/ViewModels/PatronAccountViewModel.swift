import Foundation
import SwiftData

@MainActor
@Observable
final class PatronAccountViewModel {

    // MARK: - State

    enum State: Sendable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    private(set) var state: State = .idle
    var operatorBalances: [OperatorBalance] = []

    // MARK: - Per-Operator Balance

    struct OperatorBalance: Identifiable {
        let id: String  // operator npub
        let operatorName: String
        let endpoint: String
        var balanceState: BalanceState
    }

    enum BalanceState {
        case loading
        case loaded(BalanceResult)
        case error(String)
    }

    struct BalanceResult {
        let balanceApiSats: Int
        let totalDeposited: Int
        let totalConsumed: Int
        let totalExpired: Int
        let activeTranches: Int
        let expiringWithin24h: Int
        let nextExpiration: Date?
        var tranches: [TrancheDetail] = []
        var pendingInvoiceCount: Int = 0
        var pendingInvoiceIds: [String] = []
        var invoiceSummary: InvoiceSummary?
    }

    struct InvoiceSummary {
        let totalInvoices: Int
        let settledCount: Int
        let pendingCount: Int
        let totalRealSats: Int
        let totalApiSatsCredited: Int
    }

    struct TrancheDetail: Identifiable {
        let id: String
        let amountSats: Int
        let remainingSats: Int
        let expiresAt: Date?
        let createdAt: Date?
    }

    // MARK: - Invoice History

    enum InvoiceHistoryState {
        case idle
        case loading
        case loaded([MCPService.InvoiceLineItem])
        case error(String)
    }

    /// Per-operator invoice history, keyed by operator npub
    var invoiceHistoryStates: [String: InvoiceHistoryState] = [:]

    func fetchInvoiceHistory(for patron: Patron, operator op: Operator) async {
        guard let endpointString = op.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else { return }

        invoiceHistoryStates[op.npub] = .loading

        do {
            let result = try await mcpService.callAccountStatement(
                endpointURL: endpointURL,
                patronNpub: patron.npub
            )
            invoiceHistoryStates[op.npub] = .loaded(result.invoiceItems)
        } catch {
            invoiceHistoryStates[op.npub] = .error(error.localizedDescription)
        }
    }

    func loadAllInvoiceHistory(forNpub npub: String, sources: [InvoiceSource]) async {
        await _loadAllInvoiceHistory(patronNpub: npub, sources: sources)
    }

    func loadAllInvoiceHistory(for patron: Patron, sources: [InvoiceSource]) async {
        await _loadAllInvoiceHistory(patronNpub: patron.npub, sources: sources)
    }

    private func _loadAllInvoiceHistory(patronNpub: String, sources: [InvoiceSource]) async {
        let opInfos: [(npub: String, endpoint: String)] = sources.compactMap { src in
            guard let endpoint = src.mcpEndpointURL else { return nil }
            return (src.npub, endpoint)
        }
        await withTaskGroup(
            of: (npub: String, outcome: Result<[MCPService.InvoiceLineItem], Error>).self
        ) { group in
            for info in opInfos {
                group.addTask {
                    guard let endpointURL = URL(string: info.endpoint) else {
                        return (info.npub, .failure(MCPError.connectionFailed("Invalid endpoint URL")))
                    }
                    do {
                        let result = try await self.mcpService.callAccountStatement(
                            endpointURL: endpointURL,
                            patronNpub: patronNpub
                        )
                        return (info.npub, .success(result.invoiceItems))
                    } catch {
                        return (info.npub, .failure(error))
                    }
                }
            }
            for await (npub, outcome) in group {
                switch outcome {
                case .success(let items):
                    invoiceHistoryStates[npub] = .loaded(items)
                case .failure(let error):
                    // A transient refresh failure (network, MCP hiccup,
                    // session blip) must not destroy already-loaded data.
                    // Surface .error only when we never had data to begin
                    // with; otherwise keep the prior .loaded(...) intact
                    // and log the failure for diagnostics.
                    if case .loaded = invoiceHistoryStates[npub] {
                        TrafficLogger.shared.log(
                            .error,
                            label: "Invoice History Refresh",
                            detail: "Refresh failed for \(npub.prefix(16))… — keeping prior data: \(error.localizedDescription)",
                            npub: npub
                        )
                    } else {
                        TrafficLogger.shared.log(
                            .error,
                            label: "Invoice History Load",
                            detail: "Initial load failed for \(npub.prefix(16))…: \(error.localizedDescription)",
                            npub: npub
                        )
                        invoiceHistoryStates[npub] = .error(error.localizedDescription)
                    }
                }
            }
        }
    }

    // MARK: - Cache

    private var balanceCache: [String: CachedBalance] = [:]
    private static let cacheDuration: TimeInterval = 120

    private struct CachedBalance {
        let balances: [OperatorBalance]
        let fetchedAt: Date
    }

    // MARK: - Infographic

    enum InfographicState: Equatable {
        case idle
        case loading
        case loaded(InfographicContent)
        case error(String)

        var isError: Bool {
            if case .error = self { return true }
            return false
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading): return true
            case (.error(let a), .error(let b)): return a == b
            case (.loaded(let a), .loaded(let b)): return a == b
            default: return false
            }
        }
    }

    enum InfographicContent: Equatable {
        case svg(String)
        case png(Data)
    }

    /// Per-operator infographic state, keyed by operator npub
    var infographicStates: [String: InfographicState] = [:]

    func fetchInfographic(for patron: Patron, operator op: Operator) async {
        guard let endpoint = op.mcpEndpointURL else { return }
        await fetchInfographic(patronNpub: patron.npub, serviceNpub: op.npub, endpoint: endpoint)
    }

    func fetchInfographic(patronNpub: String, serviceNpub: String, endpoint: String) async {
        guard let endpointURL = URL(string: endpoint) else { return }

        infographicStates[serviceNpub] = .loading

        do {
            let result = try await mcpService.callAccountStatementInfographic(
                endpointURL: endpointURL,
                patronNpub: patronNpub
            )

            if let svg = result.svgContent {
                infographicStates[serviceNpub] = .loaded(.svg(svg))
            } else if let pngBase64 = result.pngBase64,
                      let data = Data(base64Encoded: pngBase64) {
                infographicStates[serviceNpub] = .loaded(.png(data))
            } else {
                infographicStates[serviceNpub] = .error("No image data in response")
            }
        } catch {
            infographicStates[serviceNpub] = .error(error.localizedDescription)
        }
    }

    // MARK: - Services

    private let mcpService = MCPService()

    // MARK: - Load

    func loadBalances(for patron: Patron, sources: [InvoiceSource]) async {
        let mcpSources = sources.filter { $0.mcpEndpointURL != nil }

        guard !mcpSources.isEmpty else {
            operatorBalances = []
            state = .loaded
            return
        }

        // Check cache
        if let cached = balanceCache[patron.npub],
           Date().timeIntervalSince(cached.fetchedAt) < Self.cacheDuration {
            operatorBalances = cached.balances
            state = .loaded
            return
        }

        await _loadBalances(patronNpub: patron.npub, sources: sources)
    }

    private func _loadBalances(patronNpub: String, sources: [InvoiceSource]) async {
        let mcpSources = sources.filter { $0.mcpEndpointURL != nil }

        guard !mcpSources.isEmpty else {
            operatorBalances = []
            state = .loaded
            return
        }

        // Initialize with loading states
        operatorBalances = mcpSources.map { src in
            OperatorBalance(
                id: src.npub,
                operatorName: src.displayName,
                endpoint: src.mcpEndpointURL ?? "",
                balanceState: .loading
            )
        }
        state = .loading

        // Fetch all balances in parallel
        let opEndpoints: [(npub: String, endpoint: String)] = mcpSources.compactMap { src in
            guard let ep = src.mcpEndpointURL else { return nil }
            return (src.npub, ep)
        }
        await withTaskGroup(of: (String, BalanceState).self) { group in
            for info in opEndpoints {
                group.addTask {
                    guard let endpointURL = URL(string: info.endpoint) else {
                        return (info.npub, .error("Invalid endpoint URL"))
                    }
                    let result = await self.fetchBalance(
                        patronNpub: patronNpub,
                        operatorNpub: info.npub,
                        endpointURL: endpointURL
                    )
                    return (info.npub, result)
                }
            }
            for await (npub, result) in group {
                if let idx = operatorBalances.firstIndex(where: { $0.id == npub }) {
                    operatorBalances[idx].balanceState = result
                }
            }
        }

        balanceCache[patronNpub] = CachedBalance(
            balances: operatorBalances,
            fetchedAt: Date()
        )
        state = .loaded
    }

    func forceRefresh(forNpub npub: String, sources: [InvoiceSource]) async {
        balanceCache.removeValue(forKey: npub)

        // Both methods are internally parallelized across sources,
        // so sequential dispatch here avoids Sendable issues.
        await _loadBalances(patronNpub: npub, sources: sources)
        await _loadAllInvoiceHistory(patronNpub: npub, sources: sources)
    }

    func forceRefresh(for patron: Patron, sources: [InvoiceSource]) async {
        await forceRefresh(forNpub: patron.npub, sources: sources)
    }

    func purchaseCredits(
        patronNpub: String,
        operatorEndpoint: String,
        amountSats: Int
    ) async throws -> MCPService.PurchaseResult {
        guard let endpointURL = URL(string: operatorEndpoint) else {
            throw MCPError.connectionFailed("Invalid endpoint URL")
        }
        return try await mcpService.callPurchaseCredits(
            endpointURL: endpointURL,
            amountSats: amountSats,
            patronNpub: patronNpub
        )
    }

    // MARK: - Invoice Reconciliation

    struct ReconcileResult {
        let settled: Int
        let expired: Int
        let stillPending: Int
        let creditsGained: Int
    }

    func reconcilePendingInvoices(
        patronNpub: String,
        operatorEndpoint: String,
        pendingInvoiceIds: [String]
    ) async throws -> ReconcileResult {
        guard let endpointURL = URL(string: operatorEndpoint) else {
            throw MCPError.connectionFailed("Invalid endpoint URL")
        }

        var settled = 0, expired = 0, stillPending = 0, creditsGained = 0

        for invoiceId in pendingInvoiceIds {
            do {
                let result = try await mcpService.callCheckPayment(
                    endpointURL: endpointURL,
                    invoiceId: invoiceId,
                    npub: patronNpub
                )
                switch result.status {
                case "Settled":
                    settled += 1
                    creditsGained += result.creditsGranted
                case "Expired", "Invalid":
                    expired += 1
                default:
                    stillPending += 1
                }
            } catch {
                stillPending += 1
            }
        }

        // Invalidate cache so next balance load picks up changes
        balanceCache.removeAll()

        return ReconcileResult(
            settled: settled,
            expired: expired,
            stillPending: stillPending,
            creditsGained: creditsGained
        )
    }

    func reset() {
        state = .idle
        operatorBalances = []
    }

    // MARK: - Private

    private func fetchBalance(
        patronNpub: String,
        operatorNpub: String,
        endpointURL: URL
    ) async -> BalanceState {
        do {
            let result = try await mcpService.callCheckBalance(
                endpointURL: endpointURL,
                patronNpub: patronNpub
            )
            return .loaded(result)
        } catch {
            return .error(error.localizedDescription)
        }
    }

}
